#!/usr/bin/env python3
"""Builds the historical facts of the sights: when built and opened, architectural
style, architects, who commissioned them, and their history.

For every sight entry (Tools/capture/fetch_sight_info.py output):

1. Its Wikidata item (via the article's page properties): inception (P571),
   official opening (P1619), architectural style (P149), architect (P84),
   commissioned by (P88); labels of the referenced items in English (else German).
2. The article's wikitext: the infobox fills what Wikidata lacks (start /
   completion / opening dates, architect, style, client) and gives the building
   period as a range; the "History" ("Geschichte") section, as plain text in whole
   paragraphs up to about 1,800 characters, is the sight's history.
3. The hand-checked facts (berlin_sight_history.csv) take precedence: dates of the
   building rather than of the institution in it (Wikidata often has the founding
   year), architects, clients, and where the sight lay while the city was divided
   (East or West Berlin, which decides the ruler from 1949 to 1990).

The ruler at the time is not stored: the app derives it from the year
(MapQuestCore `BerlinEras`). Texts are from Wikipedia (CC BY-SA 4.0), facts from
Wikidata (CC0). Requests are batched (about 15), cached and patient with rate
limits (shared with fetch_sight_info.py).

With --german it also writes the facts in German: the phrases (dates in words,
styles, clients, notes on architects) from berlin_sight_history_de.csv – every
phrase needs a row there – and the history from the German article.

Usage: pip install mwparserfromhell
       python3 Tools/capture/fetch_sight_history.py App/MapQuest/Resources/Berlin/berlin-sights.json \\
           App/MapQuest/Resources/Berlin/berlin-sight-info.json \\
           App/MapQuest/Resources/Berlin/berlin-sight-history.json --cache build-sights/wiki \\
           --german-info App/MapQuest/Resources/Berlin/berlin-sight-info-de.json \\
           --german App/MapQuest/Resources/Berlin/berlin-sight-history-de.json
"""
import argparse
import csv
import json
import pathlib
import re
import sys

import mwparserfromhell

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fetch_sight_info as wiki  # noqa: E402

MAX_HISTORY = 1_800
HISTORY_SECTIONS = re.compile(r"^\s*(History|Historical background|Background|Construction|Geschichte|Baugeschichte|Entstehung)\s*$", re.I)
# The German facts take the history from the German article, whose sections are named more freely.
GERMAN_HISTORY_SECTIONS = re.compile(r"^\s*(Geschichte(?: (?:des|der|und) .*)?|Baugeschichte|Entstehung|Entstehungsgeschichte"
                                     r"|Historie|Geschichte und Architektur)\s*$", re.I)
# The language of the wikitext being rendered ("en", "de"): words added by templates follow it.
LANGUAGE = "en"
YEAR = re.compile(r"\b(1[0-9]{3}|20[0-4][0-9])\b")


def batches(items, size=50):
    items = list(items)
    for i in range(0, len(items), size):
        yield items[i:i + size]


def wikidata_ids(host: str, titles: list[str]) -> dict:
    result = {}
    for batch in batches(titles):
        data = wiki.api(host, action="query", prop="pageprops", ppprop="wikibase_item", titles="|".join(batch), redirects="1")
        back = {}
        for r in data["query"].get("normalized", []) + data["query"].get("redirects", []):
            back[r["to"]] = back.get(r["from"], r["from"])
        for page in data["query"].get("pages", []):
            qid = page.get("pageprops", {}).get("wikibase_item")
            if qid:
                result[back.get(page["title"], page["title"])] = qid
                result[page["title"]] = qid
    return result


def wikitexts(host: str, titles: list[str]) -> dict:
    result = {}
    for batch in batches(titles):
        data = wiki.api(host, action="query", prop="revisions", rvprop="content", rvslots="main", titles="|".join(batch), redirects="1")
        back = {}
        for r in data["query"].get("normalized", []) + data["query"].get("redirects", []):
            back[r["to"]] = back.get(r["from"], r["from"])
        for page in data["query"].get("pages", []):
            revisions = page.get("revisions") or []
            if revisions:
                text = revisions[0]["slots"]["main"]["content"]
                result[back.get(page["title"], page["title"])] = text
                result[page["title"]] = text
    return result


def entities(ids: list[str], props: str) -> dict:
    result = {}
    for batch in batches(sorted(set(ids))):
        data = wiki.api("www.wikidata.org", action="wbgetentities", ids="|".join(batch), props=props, languages="en|de")
        result.update(data.get("entities", {}))
    return result


def statements(entity: dict, prop: str) -> list:
    claims = [c for c in entity.get("claims", {}).get(prop, []) if c.get("rank") != "deprecated"]
    preferred = [c for c in claims if c.get("rank") == "preferred"]
    return [c["mainsnak"].get("datavalue", {}).get("value") for c in (preferred or claims) if c["mainsnak"].get("datavalue")]


def year_of(value) -> int | None:
    if isinstance(value, dict) and "time" in value and value.get("precision", 0) >= 9:
        match = re.match(r"([+-])(\d+)-", value["time"])
        if match and match.group(1) == "+":
            return int(match.group(2))
    return None


def label(entity: dict | None) -> str | None:
    if not entity:
        return None
    labels = entity.get("labels", {})
    return (labels.get("en") or labels.get("de") or {}).get("value")


UNITS = {"e6m3": "million m³", "m3": "m³", "km2": "km²", "m2": "m²", "sqkm": "km²", "sqm": "m²", "acre": "acres",
         "mi": "miles", "sqft": "sq ft", "sqmi": "sq mi", "ft": "ft", "km": "km", "m": "m", "ha": "ha", "t": "t"}
KEEP_FIRST = {"nowrap", "nobr", "small", "big", "sic", "not a typo", "linktext", "abbr", "sc", "smallcaps", "em", "strong",
              "noitalic", "nobold", "w", "lang-rtl", "ill", "interlanguage link", "interlanguage link multi", "ill2", "lw",
              "nihongo", "zitat", "zitat-de", "lang-de", "lang-en", "lang-fr", "lang-ru", "lang-it", "lang-la"}


def render_template(template) -> str:
    """The text a display template stands for (as wikitext); "" for references,
    citations, notes, coordinates and the like."""
    name = str(template.name).strip().lower().replace("_", " ")
    positional = [str(p.value).strip() for p in template.params if not p.showkey]
    if name in ("lang", "langx", "lang-rtl") and len(positional) >= 2:
        return positional[1]
    if name.startswith("lang-") and positional:
        return positional[0]
    if name in ("transl", "transliteration") and positional:
        return positional[-1]
    if name in KEEP_FIRST and positional:
        return positional[0]
    if name in ("convert", "cvt") and len(positional) >= 2:
        if positional[1] in ("to", "-", "–", "and", "x", "by") and len(positional) >= 4:
            joiner = "×" if positional[1] in ("x", "by") else "–"
            return f"{positional[0]}{joiner}{positional[2]} {UNITS.get(positional[3], positional[3])}"
        return f"{positional[0]} {UNITS.get(positional[1], positional[1])}"
    if "date" in name or name in ("dts",):
        years = [y for v in positional for y in YEAR.findall(v)]
        return "–".join(dict.fromkeys(years)) if years else ""
    if name in ("unbulleted list", "ubl", "plainlist", "plain list", "flatlist", "hlist", "bulleted list", "indented plainlist"):
        return ", ".join(re.sub(r"^\s*\*\s*", "", line) for v in positional for line in v.split("\n") if line.strip(" *"))
    if name in ("circa", "c.", "ca.", "ca"):
        return ("ca. " if LANGUAGE == "de" else "c. ") + (positional[0] if positional else "")
    if name in ("ndash", "snd", "spaced ndash"):
        return " – " if name != "ndash" else "–"
    if name in ("mdash",):
        return "—"
    if name in ("nbsp", "spaces", "sp"):
        return " "
    if name in ("höhe",) and positional:
        return positional[0] + " m"
    return ""


def expand_templates(code) -> None:
    """Replaces display templates with their text, innermost first; drops the others."""
    for template in reversed(code.filter_templates(recursive=True)):
        try:
            code.replace(template, render_template(template))
        except ValueError:
            pass


def plain(code) -> str:
    """Wikitext to plain text: no references, files or tables; display templates
    (languages, conversions, interlanguage links) become their text."""
    code = mwparserfromhell.parse(str(code))
    for tag in code.filter_tags(recursive=False):
        if str(tag.tag).lower() in ("ref", "gallery", "table", "references"):
            try:
                code.remove(tag)
            except ValueError:
                pass
    for link in code.filter_wikilinks():
        if re.match(r"^\s*(File|Image|Datei|Bild|Category|Kategorie)\s*:", str(link.title), re.I):
            try:
                code.remove(link)
            except ValueError:
                pass
    expand_templates(code)
    text = code.strip_code(normalize=True, collapse=True)
    text = re.sub(r"\{\|.*?\|\}", "", text, flags=re.S)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"\[\d+\]", "", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\s+([,.;:])", r"\1", text)
    text = re.sub(r"\(\s*[,;]?\s*\)", "", text)  # parentheses emptied by removed templates
    text = re.sub(r"\(\s*[,;]\s*", "(", text)
    text = re.sub(r"\s*\((?:see|siehe) [^()]{1,40}\)", "", text)  # pointers to maps and sections not shown
    text = re.sub(r"  +", " ", text)
    return text.strip()


def infobox(code) -> dict:
    for template in code.filter_templates(recursive=False):
        if str(template.name).strip().lower().startswith(("infobox", "info ")):
            return {str(p.name).strip().lower(): plain(p.value) for p in template.params if plain(p.value)}
    return {}


def first_value(box: dict, *names) -> str | None:
    for name in names:
        if box.get(name):
            return box[name]
    return None


def years_in(text: str | None) -> list[int]:
    return [int(y) for y in YEAR.findall(text or "")]


def history_text(code, headings=HISTORY_SECTIONS) -> str | None:
    sections = code.get_sections(levels=[2], matches=lambda heading: bool(headings.match(str(heading).strip())))
    if not sections:
        return None
    section = sections[0]
    # Without the headings of the section and its subsections.
    for heading in section.filter_headings():
        try:
            section.remove(heading)
        except ValueError:
            pass
    paragraphs = [re.sub(r"\s+", " ", p).strip() for p in plain(section).split("\n")]
    paragraphs = [p for p in paragraphs if len(p) > 60 and not p.lower().startswith(("see also", "main article", "siehe auch", "hauptartikel"))]
    result = []
    for paragraph in paragraphs:
        if result and sum(len(p) for p in result) + len(paragraph) > MAX_HISTORY:
            break
        result.append(paragraph)
    return "\n\n".join(result) or None


def read_facts(path: pathlib.Path) -> dict:
    """The hand-checked facts (`berlin_sight_history.csv`): id;year;built;opened;styles;
    architects;commissioned_by;sector. Lists are separated by "|"; an empty cell keeps
    the fetched value, "-" means none."""
    import csv
    with path.open(encoding="utf-8") as f:
        return {row["id"]: row for row in csv.DictReader(f, delimiter=";")}


def apply_facts(record: dict, facts: dict) -> dict:
    def cell(name):
        value = (facts.get(name) or "").strip()
        return None if value == "" else ("" if value == "-" else value)

    if (year := cell("year")) is not None:
        record["year"] = int(year) if year else None
    for name in ("built", "opened"):
        if (value := cell(name)) is not None:
            record[name] = value or None
    for name, key in (("styles", "styles"), ("architects", "architects"), ("commissioned_by", "commissionedBy")):
        if (value := cell(name)) is not None:
            record[key] = [v.strip() for v in value.split("|") if v.strip()]
    if (value := cell("sector")) is not None:
        record["sector"] = value or None
    return record


def read_translations(path: pathlib.Path) -> dict:
    """The German phrases of the facts: (field, English) → German (berlin_sight_history_de.csv)."""
    with open(path, encoding="utf-8") as f:
        return {(row["field"], row["en"]): row["de"] for row in csv.DictReader(f, delimiter=";") if row["de"].strip()}


def german_record(record: dict, table: dict, missing: set) -> dict:
    """The facts in German: phrases from the table; years, names and the sector as they are."""
    def phrase(field, value):
        if value is None or not re.search(r"[A-Za-z]", value):
            return value
        if (field, value) not in table:
            missing.add((field, value))
            return value
        return table[(field, value)]

    def architect(value):
        match = re.match(r"^(.*) \(([^()]*)\)$", value)
        return f"{match.group(1)} ({phrase('architectNote', match.group(2))})" if match else value

    german = dict(record)
    german["built"] = phrase("built", record["built"])
    german["opened"] = phrase("opened", record["opened"])
    german["styles"] = [phrase("style", s) for s in record["styles"]]
    german["architects"] = [architect(a) for a in record["architects"]]
    german["commissionedBy"] = [phrase("commissionedBy", c) for c in record["commissionedBy"]]
    german["history"] = None
    return german


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sights", type=pathlib.Path)
    parser.add_argument("info", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--cache", type=pathlib.Path, required=True)
    parser.add_argument("--facts", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent / "berlin_sight_history.csv",
                        help="hand-checked facts that take precedence over the fetched ones")
    parser.add_argument("--german-info", type=pathlib.Path, help="the German entries (fetch_sight_info.py --german)")
    parser.add_argument("--german", type=pathlib.Path, help="also write the facts in German")
    parser.add_argument("--translations", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parent / "berlin_sight_history_de.csv",
                        help="German phrases of the facts (field;en;de)")
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    wiki.CACHE = args.cache
    sights = json.loads(args.sights.read_text(encoding="utf-8"))["sights"]
    entries = json.loads(args.info.read_text(encoding="utf-8"))["entries"]
    facts = read_facts(args.facts)
    missing = [s["id"] for s in sights if s["id"] not in facts]
    if missing:
        sys.exit(f"no facts for: {', '.join(missing)}")

    hosts = {"en": "en.wikipedia.org", "de": "de.wikipedia.org"}
    titles = {lang: sorted({e["title"] for e in entries.values() if e["language"] == lang}) for lang in hosts}
    qids, texts = {}, {}
    for lang, host in hosts.items():
        qids[lang] = wikidata_ids(host, titles[lang])
        texts[lang] = wikitexts(host, titles[lang])
    items = entities([q for lang in qids for q in qids[lang].values()], "claims")
    referenced = set()
    for item in items.values():
        for prop in ("P84", "P149", "P88"):
            referenced |= {v["id"] for v in statements(item, prop) if isinstance(v, dict) and "id" in v}
    labels = entities(sorted(referenced), "labels")

    result = {}
    for sight in sights:
        entry = entries.get(sight["id"])
        if not entry:
            continue
        lang, title = entry["language"], entry["title"]
        qid = qids[lang].get(title)
        item = items.get(qid, {}) if qid else {}
        code = mwparserfromhell.parse(texts[lang].get(title, ""))
        box = infobox(code)

        def names(prop, *fallback):
            found = [label(labels.get(v["id"])) for v in statements(item, prop) if isinstance(v, dict) and "id" in v]
            found = [f for f in found if f]
            if found:
                return found[:4]
            text = first_value(box, *fallback)
            return [n.strip() for n in re.split(r"\s*(?:,|;|\n| and | und )\s*", text) if 2 < len(n.strip()) < 80][:4] if text else []

        start = years_in(first_value(box, "start_date", "construction_start_date", "groundbreaking_date", "baubeginn"))
        end = years_in(first_value(box, "completion_date", "completed", "construction_end_date", "fertigstellung", "bauzeit"))
        built_years = years_in(first_value(box, "built", "established", "year_built"))
        inception = next((y for y in map(year_of, statements(item, "P571")) if y), None)
        opening = next((y for y in map(year_of, statements(item, "P1619")) if y), None)
        if not opening:
            opened = years_in(first_value(box, "opened", "opening", "inauguration_date", "eröffnung", "opening_date"))
            opening = opened[0] if opened else None
        first = (start or built_years or ([inception] if inception else []) or end or ([opening] if opening else [None]))[0]
        last = (end or built_years[-1:] or [None])[-1]
        built = None
        if first:
            built = f"{first}–{last}" if last and last > first and last - first < 80 else str(first)
        style = [label(labels.get(v["id"])) for v in statements(item, "P149") if isinstance(v, dict) and "id" in v]
        style = [s for s in style if s] or ([first_value(box, "architectural_style", "style", "architecture_style", "baustil")] if first_value(box, "architectural_style", "style", "architecture_style", "baustil") else [])
        record = {
            "year": first,
            "built": built,
            "opened": str(opening) if opening and opening != first else None,
            "styles": style[:3],
            "architects": names("P84", "architect", "architects", "designer", "architekt"),
            "commissionedBy": names("P88", "client", "commissioned", "commissioned_by", "bauherr"),
            "history": history_text(code),
            "sector": None,
            "wikidata": f"https://www.wikidata.org/wiki/{qid}" if qid else None,
        }
        record = apply_facts(record, facts[sight["id"]])
        result[sight["id"]] = record
        print(f"{sight['id']:26} {str(record['built']):11} {('; '.join(record['styles']) or '-')[:28]:28} "
              f"{('; '.join(record['architects']) or '-')[:30]:30} {('; '.join(record['commissionedBy']) or '-')[:24]:24} "
              f"{len(record['history'] or '')} {record['sector']}")
    document = {
        "license": "Facts: hand-checked (Tools/capture/berlin_sight_history.csv), Wikidata (CC0) and Wikipedia infoboxes; "
                   "history texts: Wikipedia (CC BY-SA 4.0), from the article of the sight's entry.",
        "entries": result,
    }
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    if args.german:
        write_german(args, result)
    dated = sum(1 for r in result.values() if r["year"])
    print(f"{len(result)} sights: {dated} dated, {sum(1 for r in result.values() if r['architects'])} with architects, "
          f"{sum(1 for r in result.values() if r['styles'])} with style, {sum(1 for r in result.values() if r['commissionedBy'])} commissioned, "
          f"{sum(1 for r in result.values() if r['history'])} with history")


def write_german(args, result: dict) -> None:
    """The German facts: translated phrases, and the history from the German article."""
    global LANGUAGE
    if not args.german_info:
        sys.exit("--german needs --german-info")
    german_entries = json.loads(args.german_info.read_text(encoding="utf-8"))["entries"]
    titles = sorted({e["title"] for e in german_entries.values() if e["language"] == "de"})
    texts = wikitexts("de.wikipedia.org", titles)
    table = read_translations(args.translations)
    missing = set()
    german = {}
    LANGUAGE = "de"
    for sight_id, record in result.items():
        entry = german_entries.get(sight_id)
        german[sight_id] = german_record(record, table, missing)
        if entry and entry["language"] == "de":
            german[sight_id]["history"] = history_text(mwparserfromhell.parse(texts.get(entry["title"], "")), GERMAN_HISTORY_SECTIONS)
    LANGUAGE = "en"
    if missing:
        for field, value in sorted(missing):
            print(f"no German for {field}: {value}", file=sys.stderr)
        sys.exit(f"{len(missing)} phrases without German in {args.translations}")
    document = {
        "license": "Fakten: von Hand geprüft (Tools/capture/berlin_sight_history.csv, übersetzt in berlin_sight_history_de.csv), "
                   "Wikidata (CC0) und Wikipedia-Infoboxen; Geschichte: Wikipedia (CC BY-SA 4.0), aus dem deutschen Artikel.",
        "entries": german,
    }
    args.german.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"German: {len(german)} sights, {sum(1 for r in german.values() if r['history'])} with history")


if __name__ == "__main__":
    main()
