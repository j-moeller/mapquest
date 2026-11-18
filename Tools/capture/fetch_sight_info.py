#!/usr/bin/env python3
"""Builds the encyclopedia entries of the sights from Wikipedia and Wikimedia Commons.

For every sight of a sight list (Tools/capture/locate_sights.py output):

1. Its name and aliases are looked up as German Wikipedia article titles (50 per
   request); names that are no article are searched (one request each). The
   first article whose coordinates lie near the sight (600 m, more for large
   sights) is its article – matching by position, so a same-named place
   elsewhere cannot slip in.
2. The text is the introduction of the English article (via the language link),
   or of the German one if there is no English article: plain text, pronunciation
   notes removed, whole paragraphs up to about 1,400 characters.
3. The photo is the article's lead image if it is a photo (no SVG drawing or
   logo) on Wikimedia Commons (free licence): a 960-pixel thumbnail URL, its
   file page, author and licence.

Texts are from Wikipedia (CC BY-SA 4.0); the output keeps title and URL of every
article and author and licence of every photo for attribution. Polite: an
identifying User-Agent, one request at a time, batched (about 40 requests for
119 sights), answers cached in --cache.

Usage: python3 Tools/capture/fetch_sight_info.py App/MapQuest/Resources/Berlin/berlin-sights.json \
           App/MapQuest/Resources/Berlin/berlin-sight-info.json --cache build-sights/wiki \
           --aliases Tools/capture/berlin_sights.csv --overrides Tools/capture/berlin_sight_articles.csv \
           --german App/MapQuest/Resources/Berlin/berlin-sight-info-de.json

With --german it also writes the German entries: the German articles' introductions.

Overrides (id;German article title, or "-" for none) fix sights whose name is no
article and whose search finds a neighbouring one (they skip the position check).
"""
import argparse
import csv
import hashlib
import html
import json
import math
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request

USER_AGENT = "MapQuest-tools/1 (https://github.com/j-moeller/mapquest; sight entries build)"
MAX_TEXT = 1_400


CACHE: pathlib.Path | None = None


def api(host: str, **params) -> dict:
    """One API request: answers are cached on disk (re-runs are cheap); paced and
    patient with rate limits (429), which shared networks hit often."""
    params = {"format": "json", "formatversion": "2", "maxlag": "5", **params}
    url = f"https://{host}/w/api.php?" + urllib.parse.urlencode(params)
    cached = CACHE / (hashlib.sha1(url.encode()).hexdigest() + ".json") if CACHE else None
    if cached and cached.exists():
        return json.loads(cached.read_text(encoding="utf-8"))
    for attempt in range(20):
        time.sleep(1.5)
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                data = json.loads(response.read())
        except urllib.error.HTTPError as error:
            if error.code in (429, 503) and attempt < 19:
                wait = int(error.headers.get("Retry-After") or 0) or 15 * (attempt + 1)
                print(f"  {error.code}, waiting {wait} s", file=sys.stderr, flush=True)
                time.sleep(wait)
                continue
            raise
        if data.get("error", {}).get("code") == "maxlag":
            # Wikidata's replicas lag behind at times: wait longer each time.
            print(f"  maxlag, waiting {10 * (attempt + 1)} s", file=sys.stderr, flush=True)
            time.sleep(10 * (attempt + 1))
            continue
        if cached:
            cached.write_text(json.dumps(data), encoding="utf-8")
        return data
    raise RuntimeError(f"no answer from {host}")


def distance(a, b) -> float:
    dy = (a[0] - b[0]) * 111_320
    dx = (a[1] - b[1]) * 111_320 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def coordinates_of(titles: list[str]) -> tuple[dict, dict]:
    """Article coordinates (after redirects) of up to 50 titles per request, and the redirect map."""
    coordinates, redirects = {}, {}
    for i in range(0, len(titles), 50):
        batch = titles[i:i + 50]
        data = api("de.wikipedia.org", action="query", prop="coordinates", titles="|".join(batch),
                   colimit="max", redirects="1")
        for r in data["query"].get("redirects", []) + data["query"].get("normalized", []):
            redirects[r["from"]] = r["to"]
        for page in data["query"].get("pages", []):
            if page.get("coordinates"):
                c = page["coordinates"][0]
                coordinates[page["title"]] = (c["lat"], c["lon"])
    return coordinates, redirects


def resolve(title: str, redirects: dict) -> str:
    for _ in range(3):
        title = redirects.get(title, title)
    return title


def pick(sight: dict, titles: list[str], coordinates: dict, redirects: dict, forced: bool = False):
    """The first title whose article lies near the sight (any, if forced by an override)."""
    position = (sight["latitude"], sight["longitude"])
    limit = max(600, 6 * sight["radius"])
    for title in titles:
        title = resolve(title, redirects)
        if title in coordinates:
            d = distance(position, coordinates[title])
            if forced or d <= limit:
                return title, d
        elif forced:
            return title, -1.0  # an override without coordinates in the article
    return None


def search_article(sight: dict):
    """Fallback for names that are not article titles: a full-text search."""
    titles = []
    for query in (sight["name"], f'{sight["name"]} Berlin'):
        result = api("de.wikipedia.org", action="query", list="search", srsearch=query, srlimit="8", srnamespace="0")
        titles += [hit["title"] for hit in result["query"]["search"] if hit["title"] not in titles]
        coordinates, redirects = coordinates_of(titles)
        found = pick(sight, titles, coordinates, redirects)
        if found:
            return found
    return None


def pages(host: str, titles: list[str], **params) -> dict:
    """Pages by (resolved) title, 20 per request (the limit for introductions)."""
    result = {}
    for i in range(0, len(titles), 20):
        batch = titles[i:i + 20]
        data = api(host, action="query", titles="|".join(batch), redirects="1", **params)
        mapping = {}
        for r in data["query"].get("normalized", []) + data["query"].get("redirects", []):
            mapping[r["to"]] = mapping.get(r["from"], r["from"])
        for page in data["query"].get("pages", []):
            if page.get("missing"):
                continue
            result[page["title"]] = page
            if page["title"] in mapping:
                result[mapping[page["title"]]] = page
    return result


def clean(text: str) -> str:
    """Plain introduction: no pronunciation notes, whole paragraphs up to MAX_TEXT."""
    # Parentheses with pronunciations, IPA or audio hints.
    text = re.sub(r"\s*\([^()]*(?:pronounced|Aussprache|\[|listen|anhören|ⓘ)[^()]*\)", "", text)
    # Pronunciations in brackets (IPA): "Schloss Bellevue [ʃlɔs bɛlˈvyː]".
    text = re.sub(r"\s*\[[^\]]*[ˈˌːʃʒŋɐəɛɔʊʏøœɪʁχç][^\]]*\]", "", text)
    # What remains of nested ones: "()" or "(; …)".
    text = re.sub(r"\s*\(\s*[;,]?\s*\)", "", text)
    text = re.sub(r"\(\s*[;,]\s*", "(", text)
    paragraphs = [re.sub(r"\s+", " ", p).strip() for p in text.split("\n")]
    paragraphs = [p for p in paragraphs if len(p) > 40]
    result = []
    for paragraph in paragraphs:
        if result and sum(len(p) for p in result) + len(paragraph) > MAX_TEXT:
            break
        result.append(paragraph)
    return "\n\n".join(result)


def photo_name(page: dict) -> str | None:
    """The article's lead image if it is a photo – not a logo, map or other drawing (SVG)."""
    name = page.get("pageimage")
    if not name or name.lower().endswith(".svg") or "logo" in name.lower():
        return None
    return name


def commons_images(names: list[str]) -> dict:
    """Free Commons photos by file name (50 per request): thumbnail, file page, author, licence."""
    result = {}
    for i in range(0, len(names), 50):
        batch = names[i:i + 50]
        data = api("commons.wikimedia.org", action="query", titles="|".join(f"File:{n}" for n in batch),
                   prop="imageinfo", iiprop="url|extmetadata", iiurlwidth="960")
        normalized = {r["to"]: r["from"] for r in data["query"].get("normalized", [])}
        for page in data["query"].get("pages", []):
            info = (page.get("imageinfo") or [None])[0]
            if not info or page.get("missing"):
                continue  # not on Commons (e.g. a non-free local file)
            meta = info.get("extmetadata", {})

            def value(key):
                raw = meta.get(key, {}).get("value", "")
                return html.unescape(re.sub(r"<[^>]+>", "", str(raw))).strip()

            license_name = value("LicenseShortName")
            if not license_name or "fair use" in license_name.lower():
                continue
            name = normalized.get(page["title"], page["title"]).removeprefix("File:")
            result[name] = result[page["title"].removeprefix("File:")] = {
                "url": info.get("thumburl") or info["url"],
                "page": info["descriptionurl"],
                "artist": re.sub(r"\s+", " ", value("Artist"))[:120] or "Unknown",
                "license": license_name,
                "licenseURL": value("LicenseUrl") or None,
            }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sights", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--overrides", type=pathlib.Path, help="id;German article title (or '-' for none)")
    parser.add_argument("--cache", type=pathlib.Path, help="directory for cached API answers")
    parser.add_argument("--aliases", type=pathlib.Path, help="the sight list with aliases (id;…;aliases), e.g. berlin_sights.csv")
    parser.add_argument("--german", type=pathlib.Path,
                        help="also write the German entries (the German introductions; English where there is no German article)")
    args = parser.parse_args()
    global CACHE
    if args.cache:
        args.cache.mkdir(parents=True, exist_ok=True)
        CACHE = args.cache
    sights = json.loads(args.sights.read_text(encoding="utf-8"))["sights"]
    overrides = {}
    if args.overrides and args.overrides.exists():
        with open(args.overrides, encoding="utf-8") as f:
            overrides = {row["id"]: row["article"] for row in csv.DictReader(f, delimiter=";")}
    aliases = {}
    if args.aliases and args.aliases.exists():
        with open(args.aliases, encoding="utf-8") as f:
            aliases = {row["id"]: [a for a in row["aliases"].split("|") if a and not a.startswith("@")]
                       for row in csv.DictReader(f, delimiter=";")}

    # 1. Names and aliases as article titles (50 per request), checked by position.
    candidates = {}
    for sight in sights:
        override = overrides.get(sight["id"])
        if override == "-":
            continue
        names = [override] if override else [sight["name"]] + aliases.get(sight["id"], [])
        candidates[sight["id"]] = list(dict.fromkeys(names))
    coordinates, redirects = coordinates_of(sorted({t for ts in candidates.values() for t in ts}))
    matches, missing = {}, []
    for sight in sights:
        if sight["id"] not in candidates:
            missing.append(sight["id"])
            continue
        found = pick(sight, candidates[sight["id"]], coordinates, redirects, forced=sight["id"] in overrides)
        # 2. Otherwise a full-text search (one request each).
        found = found or search_article(sight)
        if found:
            matches[sight["id"]] = found
        else:
            missing.append(sight["id"])
            print(f"MISSING {sight['id']}: {sight['name']}", file=sys.stderr)

    # 3. German introductions, photos and English links; 4. English introductions.
    de_pages = pages("de.wikipedia.org", sorted({t for t, _ in matches.values()}), prop="extracts|pageimages|info|langlinks",
                     exintro="1", explaintext="1", exlimit="20", piprop="name", pilimit="50", inprop="url",
                     lllang="en", lllimit="500")
    en_titles = {}
    for sight_id, (title, _) in matches.items():
        page = de_pages.get(title)
        link = next((l["title"] for l in (page or {}).get("langlinks", []) if l["lang"] == "en"), None)
        if link:
            en_titles[sight_id] = link
    en_pages = pages("en.wikipedia.org", sorted(set(en_titles.values())), prop="extracts|pageimages|info",
                     exintro="1", explaintext="1", exlimit="20", piprop="name", pilimit="50", inprop="url")

    # 5. Photos (German lead image first: German Wikipedia only uses free images).
    image_names = set()
    for sight_id, (title, _) in matches.items():
        for page in (de_pages.get(title), en_pages.get(en_titles.get(sight_id, ""))):
            if page and photo_name(page):
                image_names.add(photo_name(page))
    images = commons_images(sorted(image_names))

    entries = {}
    german = {}
    for sight in sights:
        if sight["id"] not in matches:
            continue
        title, d = matches[sight["id"]]
        de = de_pages.get(title)
        en = en_pages.get(en_titles.get(sight["id"], ""))
        # English, unless its introduction is a stub next to a much longer German one.
        en_text = clean(en.get("extract", "")) if en else ""
        de_text = clean(de.get("extract", "")) if de else ""
        stub = len(en_text) < 200 and len(de_text) > 2 * len(en_text)
        source = en if en_text and not stub else de
        text = clean(source.get("extract", "")) if source else ""
        if not text:
            missing.append(sight["id"])
            continue
        image = None
        for page in (de, en):
            if page and photo_name(page) in images:
                image = images[photo_name(page)]
                break
        entries[sight["id"]] = {
            "title": source["title"],
            "language": "en" if source is en else "de",
            "url": source["fullurl"],
            "text": text,
            "image": image,
        }
        # German: the German introduction (the article the sight was matched with).
        german_source = de if de_text else source
        german[sight["id"]] = {
            "title": german_source["title"],
            "language": "de" if german_source is de else "en",
            "url": german_source["fullurl"],
            "text": de_text or text,
            "image": image,
        }
        print(f"{sight['id']:28} {d:5.0f} m  {title} -> {source['title']} ({entries[sight['id']]['language']}, "
              f"{len(text)} chars, {'photo' if image else 'no photo'})")
    document = {
        "license": "Texts: Wikipedia, CC BY-SA 4.0 (article per entry). Photos: Wikimedia Commons, author and licence per entry.",
        "entries": entries,
    }
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    if args.german:
        document_de = {
            "license": "Texte: Wikipedia, CC BY-SA 4.0 (Artikel je Eintrag). Fotos: Wikimedia Commons, Urheber und Lizenz je Eintrag.",
            "entries": german,
        }
        args.german.write_text(json.dumps(document_de, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"German: {len(german)} entries, {sum(1 for e in german.values() if e['language'] == 'de')} from German articles")
    print(f"{len(entries)} entries, {sum(1 for e in entries.values() if e['image'])} with photo; missing: {', '.join(missing)}")


if __name__ == "__main__":
    main()
