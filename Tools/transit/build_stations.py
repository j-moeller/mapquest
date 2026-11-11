#!/usr/bin/env python3
"""Builds the U-Bahn and S-Bahn stations of Berlin and their lines for the capture
component (berlin-stations.json).

Source: the OpenStreetMap route relations of the lines (route=subway for U1–U9,
route=light_rail for the S-Bahn lines; © OpenStreetMap contributors, ODbL),
fetched from an Overpass server into --routes (kept, so re-runs work offline):

  [out:json][timeout:240];
  rel["type"="route"]["route"~"^(subway|light_rail|train)$"]["ref"~"^(U[1-9]|S[0-9]+)$"](52.0,12.6,53.0,14.2);
  out body;
  node(r);
  out body;

For every line, its stops (members with a role starting with "stop") in the order
of its longest route variant; stops of the other variants not on it are inserted
after their predecessor. A station is a name within a system (U or S): the
U-Bahn and S-Bahn stations of e.g. Alexanderplatz are two stations. Its position
is the mean of its stop positions; unnamed stops take the name of the nearest
named stop of the system within 400 m. --additions adds stations missing from
the routes (line;after;name;lat;lon;source). Names lose "S+U"/"S"/"U" prefixes
and suffixes such as "(bei Berlin)". With --districts every station inside Berlin
gets its district.

Usage: python3 Tools/transit/build_stations.py --routes build-stations/routes.json \\
           --additions Tools/transit/berlin_station_additions.csv \\
           --districts App/MapQuest/Resources/Berlin/berlin-districts.geojson \\
           App/MapQuest/Resources/Berlin/berlin-stations.json
"""
import argparse
import csv
import json
import math
import pathlib
import re
import sys
import unicodedata
import urllib.parse
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "capture"))
from locate_sights import district_of, read_districts  # noqa: E402

QUERY = """[out:json][timeout:240];
rel["type"="route"]["route"~"^(subway|light_rail|train)$"]["ref"~"^(U[1-9]|S[0-9]+)$"](52.0,12.6,53.0,14.2);
out body;
node(r);
out body;"""
SERVERS = ["https://overpass-api.de/api/interpreter", "https://overpass.private.coffee/api/interpreter",
           "https://overpass.kumi.systems/api/interpreter"]
RADIUS = 80  # metres: platforms are long, the circles of the radius view must reach within 30 m


def fetch_routes(path: pathlib.Path):
    data = urllib.parse.urlencode({"data": QUERY}).encode()
    for server in SERVERS:
        try:
            request = urllib.request.Request(server, data=data, headers={"User-Agent": "MapQuest-tools/1 (station list build)"})
            with urllib.request.urlopen(request, timeout=300) as response:
                body = response.read()
            json.loads(body)
            path.write_bytes(body)
            return
        except Exception as error:  # try the next server
            print(f"{server}: {error}", file=sys.stderr)
    sys.exit("no Overpass server answered")


def clean(name: str) -> str:
    name = re.sub(r"^(S\+U|U\+S|S|U)\s+", "", name.strip())
    name = re.sub(r"\s*\((bei|b\.?) [^)]*\)$", "", name)
    name = re.sub(r"\s*\((Teltow-Fläming|Mark)\)$", "", name)
    return name.strip()


def slug(name: str) -> str:
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss"), ("Ä", "Ae"), ("Ö", "Oe"), ("Ü", "Ue")):
        name = name.replace(a, b)
    name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def distance(a, b) -> float:
    dy = (a[0] - b[0]) * 111_320
    dx = (a[1] - b[1]) * 111_320 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def line_key(ref: str):
    """U1…U9, then S1, S15, S2, S25, S26, S3, S41… as the BVG lists them."""
    return (0 if ref.startswith("U") else 1, re.sub(r"\D", "", ref))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--routes", type=pathlib.Path, required=True, help="Overpass answer (fetched if missing)")
    parser.add_argument("--additions", type=pathlib.Path)
    parser.add_argument("--districts", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    if not args.routes.exists():
        args.routes.parent.mkdir(parents=True, exist_ok=True)
        fetch_routes(args.routes)
    data = json.loads(args.routes.read_text(encoding="utf-8"))
    nodes = {e["id"]: e for e in data["elements"] if e["type"] == "node"}
    relations = [e for e in data["elements"] if e["type"] == "relation"]

    # Stop nodes per system, named.
    def system(relation):
        return "U" if relation["tags"]["route"] == "subway" else "S"

    named = {"U": [], "S": []}
    for relation in relations:
        for member in relation["members"]:
            node = nodes.get(member["ref"]) if member["type"] == "node" else None
            if node and member["role"].startswith("stop") and node.get("tags", {}).get("name"):
                named[system(relation)].append(node)

    def name_of(node, sys_):
        if node.get("tags", {}).get("name"):
            return clean(node["tags"]["name"])
        near = min(named[sys_], key=lambda n: distance((n["lat"], n["lon"]), (node["lat"], node["lon"])), default=None)
        if near and distance((near["lat"], near["lon"]), (node["lat"], node["lon"])) <= 400:
            return clean(near["tags"]["name"])
        return None

    positions = {}  # (system, name) -> [(lat, lon)]
    variants = {}   # ref -> [[names in order]]
    colours = {}
    for relation in relations:
        ref, sys_ = relation["tags"]["ref"], system(relation)
        colours.setdefault(ref, relation["tags"].get("colour", "#888888").upper())
        order = []
        for member in relation["members"]:
            node = nodes.get(member["ref"]) if member["type"] == "node" else None
            if not node or not member["role"].startswith("stop"):
                continue
            name = name_of(node, sys_)
            if not name:
                print(f"{ref}: unnamed stop {node['id']} left out", file=sys.stderr)
                continue
            positions.setdefault((sys_, name), []).append((node["lat"], node["lon"]))
            if not order or order[-1] != name:
                order.append(name)
        if len(order) > 1 and order[0] == order[-1]:
            order.pop()  # the Ring ends where it starts
        variants.setdefault(ref, []).append(order)

    lines = {}
    for ref, orders in variants.items():
        orders.sort(key=len, reverse=True)
        stations = list(orders[0])
        for order in orders[1:]:
            for i, name in enumerate(order):
                if name in stations:
                    continue
                before = next((order[j] for j in range(i - 1, -1, -1) if order[j] in stations), None)
                stations.insert(stations.index(before) + 1 if before else 0, name)
        lines[ref] = stations

    if args.additions:
        with args.additions.open(encoding="utf-8") as f:
            for row in csv.DictReader(f, delimiter=";"):
                ref, sys_ = row["line"], row["line"][0]
                stations = lines[ref]
                stations.insert(stations.index(row["after"]) + 1, row["name"])
                positions.setdefault((sys_, row["name"]), []).append((float(row["lat"]), float(row["lon"])))

    districts = read_districts(args.districts) if args.districts else []
    station_lines = {}
    for ref, stations in lines.items():
        for name in stations:
            station_lines.setdefault((ref[0], name), set()).add(ref)
    stations = []
    for (sys_, name), refs in sorted(station_lines.items(), key=lambda item: (item[0][0] != "U", slug(item[0][1]))):
        points = positions[(sys_, name)]
        lat = sum(p[0] for p in points) / len(points)
        lon = sum(p[1] for p in points) / len(points)
        station = {
            "id": f"{sys_.lower()}:{slug(name)}", "name": name, "system": sys_,
            "lines": sorted(refs, key=line_key), "latitude": round(lat, 6), "longitude": round(lon, 6), "radius": RADIUS,
        }
        if districts:
            district = district_of(districts, lat, lon)
            if district:
                station["district"] = district
        stations.append(station)
    ids = {(s["system"], s["name"]): s["id"] for s in stations}
    assert len(set(ids.values())) == len(ids), "station IDs are unique"
    document = {
        "source": "OpenStreetMap route relations of the U-Bahn and S-Bahn lines (© OpenStreetMap contributors, ODbL), "
                  "Tools/transit/build_stations.py; additions from Wikipedia (Tools/transit/berlin_station_additions.csv)",
        "lines": [
            {"id": ref, "system": ref[0], "colour": colours[ref],
             "name": "Ringbahn" if ref in ("S41", "S42") else f"{lines[ref][0]} – {lines[ref][-1]}",
             "stations": [ids[(ref[0], name)] for name in lines[ref]]}
            for ref in sorted(lines, key=line_key)
        ],
        "stations": stations,
    }
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    for line in document["lines"]:
        print(f"{line['id']:4} {len(line['stations']):3} stations  {line['colour']}  {line['name']}")
    u = sum(1 for s in stations if s["system"] == "U")
    print(f"{len(stations)} stations: {u} U-Bahn, {len(stations) - u} S-Bahn; "
          f"{sum(1 for s in stations if 'district' in s)} in Berlin")


if __name__ == "__main__":
    main()
