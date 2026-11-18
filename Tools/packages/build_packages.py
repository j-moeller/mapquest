#!/usr/bin/env python3
"""Builds MapQuest's own sight packages (docs/09-sight-packages.md) from the build
tools' source files in Packages/sources/<city>/:

  <city>-sights.json           Tools/capture/locate_sights.py
  <city>-sight-info[-de].json  Tools/capture/fetch_sight_info.py
  <city>-sight-history[-de].json  Tools/capture/fetch_sight_history.py
  <city>-chronicle.json        eras and rulers (edited by hand)
  <city>-achievements.json     achievements (edited by hand; title/description, de)
  <city>-remembrance[-de].json places of remembrance (edited by hand)
  <city>-stations.json         Tools/transit/build_stations.py (Berlin)

Each city becomes several packages that compose: standalone parts (its churches,
its places of remembrance with their walks, its transit) and the city package,
which includes them and adds everything else. Written:

  Packages/<city>.sights.json         the city: a bundle of all its packages
  Packages/parts/<id>.sights.json     each package on its own
  App/MapQuest/Resources/Packages/    the bundles the app installs on first launch (--no-app: not)

Usage: python3 Tools/packages/build_packages.py [--version 2026.11.18] [--no-app]
"""
import argparse
import datetime
import json
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Packages" / "sources"
PUBLISHER = "MapQuest"

CITIES = {
    "berlin": {
        "name": {"en": "Berlin"},
        "parts": [
            {"suffix": "churches", "title": {"en": "Berlin churches", "de": "Berliner Kirchen"},
             "summary": {"en": "Berlin's churches – from the medieval town churches to the cathedral – with their history and an achievement for all of them.",
                         "de": "Berlins Kirchen – von den mittelalterlichen Stadtkirchen bis zum Dom – mit ihrer Geschichte und einem Erfolg für alle."},
             "categories": {"church"}, "achievements": {"churches"}},
            {"suffix": "remembrance", "title": {"en": "Berlin remembers", "de": "Berlin erinnert"},
             "summary": {"en": "Berlin's memorials, memorial sites and cemeteries as a short history in chapters, with walks. Outside the game.",
                         "de": "Berlins Gedenkstätten, Mahnmale und Friedhöfe als kurze Geschichte in Kapiteln, mit Spaziergängen. Außerhalb des Spiels."},
             "remembrance": True},
            {"suffix": "transit", "title": {"en": "Berlin U-Bahn and S-Bahn", "de": "Berliner U- und S-Bahn"},
             "summary": {"en": "Every U-Bahn and S-Bahn station of Berlin to collect by going there, and an achievement for each line.",
                         "de": "Jeder U- und S-Bahnhof Berlins zum Sammeln, indem du hingehst, und ein Erfolg für jede Linie."},
             "transit": True},
        ],
        "title": {"en": "Berlin", "de": "Berlin"},
        "summary": {"en": "184 sights in all of Berlin's districts with their entries and history – who built them and who ruled then – achievements, Berlin's places of remembrance and its U-Bahn and S-Bahn.",
                    "de": "184 Sehenswürdigkeiten in allen Berliner Bezirken mit Einträgen und Geschichte – wer sie erbaute und wer damals regierte –, Erfolgen, Berlins Gedenkorten und seiner U- und S-Bahn."},
    },
    "braunschweig": {
        "name": {"en": "Braunschweig"},
        "parts": [
            {"suffix": "churches", "title": {"en": "Braunschweig churches", "de": "Braunschweiger Kirchen"},
             "summary": {"en": "Henry the Lion's cathedral, the town churches of the five boroughs and Riddagshausen abbey.",
                         "de": "Der Dom Heinrichs des Löwen, die Stadtkirchen der fünf Weichbilde und das Kloster Riddagshausen."},
             "categories": {"church"}, "achievements": {"bs-churches"}},
            {"suffix": "remembrance", "title": {"en": "Braunschweig remembers", "de": "Braunschweig erinnert"},
             "summary": {"en": "Braunschweig's places of remembrance as a short history, with a walk. Outside the game.",
                         "de": "Braunschweigs Gedenkorte als kurze Geschichte, mit einem Spaziergang. Außerhalb des Spiels."},
             "remembrance": True},
        ],
        "title": {"en": "Braunschweig", "de": "Braunschweig"},
        "summary": {"en": "Braunschweig's sights with their entries and history – from the Brunonen and Henry the Lion to Lower Saxony – achievements and places of remembrance.",
                    "de": "Braunschweigs Sehenswürdigkeiten mit Einträgen und Geschichte – von den Brunonen und Heinrich dem Löwen bis Niedersachsen –, Erfolgen und Gedenkorten."},
    },
}
REMEMBRANCE = {"memorial", "cemetery"}
LICENSE = ("Texts: Wikipedia (CC BY-SA 4.0); photos: Wikimedia Commons (licence per photo); "
           "facts: Wikidata (CC0), hand-checked; positions: OpenStreetMap (ODbL 1.0); "
           "achievements, chronicles and remembrance texts: MapQuest")


def load(path):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def bounds(city):
    """The bounding box of the city's outline (App/MapQuest/Resources/<City>/<city>-boundary.geojson)."""
    path = ROOT / "App" / "MapQuest" / "Resources" / city.capitalize() / f"{city}-boundary.geojson"
    if not path.exists():
        return None
    points = []

    def walk(value):
        if isinstance(value, list) and len(value) >= 2 and all(isinstance(v, (int, float)) for v in value[:2]):
            points.append(value)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    for feature in load(path).get("features", []):
        walk(feature["geometry"]["coordinates"])
    if not points:
        return None
    return {"south": round(min(p[1] for p in points), 4), "west": round(min(p[0] for p in points), 4),
            "north": round(max(p[1] for p in points), 4), "east": round(max(p[0] for p in points), 4)}


def localized(en, de):
    """A localized text: {"en", "de"} (German left out where it is the same)."""
    if en is None and de is None:
        return None
    if de is None or de == en:
        return {"en": en}
    return {"en": en, "de": de}


def clean(d):
    return {k: v for k, v in d.items() if v not in (None, [], {}, "")}


def facts_texts(record):
    return clean({"built": record.get("built"), "opened": record.get("opened"), "styles": record.get("styles"),
                  "architects": record.get("architects"), "commissionedBy": record.get("commissionedBy"),
                  "history": record.get("history")})


def city_content(city):
    src = SOURCES / city
    sights = load(src / f"{city}-sights.json")["sights"]
    info = {lang: (load(src / f"{city}-sight-info{suffix}.json") or {"entries": {}})["entries"]
            for lang, suffix in (("en", ""), ("de", "-de"))}
    history = {lang: (load(src / f"{city}-sight-history{suffix}.json") or {"entries": {}})["entries"]
               for lang, suffix in (("en", ""), ("de", "-de"))}
    chronicle = load(src / f"{city}-chronicle.json")
    achievements = (load(src / f"{city}-achievements.json") or {"achievements": []})["achievements"]
    remembrance = {lang: load(src / f"{city}-remembrance{suffix}.json") for lang, suffix in (("en", ""), ("de", "-de"))}
    stations = load(src / f"{city}-stations.json")

    items = {}
    for s in sights:
        en = history["en"].get(s["id"])
        de = history["de"].get(s["id"])
        sight = {
            "id": s["id"], "name": s["name"], "names": {"en": s["nameEn"]} if s.get("nameEn") else None,
            "category": s["category"], "latitude": s["latitude"], "longitude": s["longitude"],
            "radius": s.get("radius"), "district": s.get("district"),
        }
        if en and en.get("wikidata"):
            sight["wikidata"] = en["wikidata"].rsplit("/", 1)[-1]
        entry = {lang: info[lang][s["id"]] for lang in ("en", "de") if s["id"] in info[lang]}
        if entry:
            sight["entry"] = entry
        if en:
            localized_facts = {"en": facts_texts(en)}
            if de:
                localized_facts["de"] = facts_texts(de)
            sight["facts"] = clean({"year": en.get("year"), "sector": en.get("sector"), "wikidata": en.get("wikidata"),
                                    "localized": {k: v for k, v in localized_facts.items() if v}})
        items[s["id"]] = clean(sight)

    def achievement(a):
        de = a.get("de") or {}
        return {"id": a["id"], "group": a["group"], "symbol": a["symbol"],
                "title": localized(a["title"], de.get("title")),
                "description": localized(a["description"], de.get("description")), "rule": a["rule"]}

    guide = None
    if remembrance["en"]:
        german = {c["id"]: c for c in (remembrance["de"] or {}).get("chapters", [])}
        german_tours = {t["id"]: t for t in (remembrance["de"] or {}).get("tours", [])}
        chapters = []
        for c in remembrance["en"]["chapters"]:
            g = german.get(c["id"], {})
            places = []
            g_places = {p["sight"]: p for p in g.get("places", [])}
            for p in c["places"]:
                places.append({"sight": p["sight"], "remembers": localized(p["remembers"], g_places.get(p["sight"], {}).get("remembers"))})
            chapters.append(clean({"id": c["id"], "title": localized(c["title"], g.get("title")),
                                   "years": localized(c.get("years") or None, g.get("years") or None),
                                   "text": localized(c["text"], g.get("text")), "places": places}))
        tours = []
        for t in remembrance["en"].get("tours", []):
            g = german_tours.get(t["id"], {})
            tours.append({"id": t["id"], "title": localized(t["title"], g.get("title")),
                          "text": localized(t["text"], g.get("text")), "stops": t["stops"]})
        guide = {"chapters": chapters, "tours": tours}

    transit = None
    if stations:
        transit = {
            "lines": stations["lines"],
            "stations": [clean({"id": s["id"], "name": s["name"], "names": {"en": s["nameEn"]} if s.get("nameEn") else None,
                                "system": s["system"], "lines": s["lines"], "latitude": s["latitude"],
                                "longitude": s["longitude"], "radius": s.get("radius"), "district": s.get("district")})
                         for s in stations["stations"]],
        }
    return items, [achievement(a) for a in achievements], chronicle, guide, transit


def package(pid, version, title, summary, region, chronicle, sights=None, achievements=None, includes=None,
            remembrance=None, transit=None):
    return clean({
        "id": pid, "version": version, "title": title, "summary": summary, "publisher": PUBLISHER,
        "license": LICENSE, "language": "de", "region": region, "includes": includes,
        "chronicles": [chronicle] if chronicle and sights else None,
        "sights": sights, "achievements": achievements, "remembrance": remembrance, "transit": transit,
    })


def write(path, packages):
    path.parent.mkdir(parents=True, exist_ok=True)
    if len(packages) == 1:
        document = {"format": "mapquest-sights", "formatVersion": 1, **packages[0]}
    else:
        document = {"format": "mapquest-sights", "formatVersion": 1, "packages": packages}
    path.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", default=datetime.date.today().strftime("%Y.%m.%d"))
    parser.add_argument("--no-app", action="store_true", help="do not copy the bundles into the app")
    args = parser.parse_args()
    app = ROOT / "App" / "MapQuest" / "Resources" / "Packages"
    for city, config in CITIES.items():
        sights, achievements, chronicle, guide, transit = city_content(city)
        region = clean({"id": city, "name": config["name"], "bounds": bounds(city)})
        taken_sights, taken_achievements, packages = set(), set(), []
        for part in config["parts"]:
            pid = f"mapquest.{city}.{part['suffix']}"
            if part.get("remembrance"):
                members = [s for s in sights.values() if s["category"] in REMEMBRANCE]
            else:
                members = [s for s in sights.values() if s["category"] in part.get("categories", set())]
            if part.get("transit"):
                own = [a for a in achievements if a["group"] == "lines" or a["rule"].get("places") == "stations"
                       or a["rule"].get("line") or a["rule"].get("system")]
            else:
                own = [a for a in achievements if a["id"] in part.get("achievements", set())]
            taken_sights |= {s["id"] for s in members}
            taken_achievements |= {a["id"] for a in own}
            packages.append(package(pid, args.version, part["title"], part["summary"], region, chronicle,
                                    sights=members or None, achievements=own or None,
                                    remembrance=guide if part.get("remembrance") else None,
                                    transit=transit if part.get("transit") else None))
        main_package = package(
            f"mapquest.{city}", args.version, config["title"], config["summary"], region, chronicle,
            sights=[s for s in sights.values() if s["id"] not in taken_sights],
            achievements=[a for a in achievements if a["id"] not in taken_achievements],
            includes=[p["id"] for p in packages],
        )
        packages.insert(0, main_package)
        write(ROOT / "Packages" / f"{city}.sights.json", packages)
        for p in packages:
            write(ROOT / "Packages" / "parts" / f"{p['id']}.sights.json", [p])
        if not args.no_app:
            app.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / "Packages" / f"{city}.sights.json", app / f"{city}.sights.json")
        counts = ", ".join(f"{p['id']}: {len(p.get('sights', []))} sights, {len(p.get('achievements', []))} achievements"
                           for p in packages)
        print(f"{city}: {counts}")


if __name__ == "__main__":
    main()
