#!/usr/bin/env python3
"""Locates the curated sights of a city in OpenStreetMap and writes the app's sight list.

Input: a semicolon-separated list (id;name;category;lat;lon;radius;aliases) with
approximate positions, e.g. Tools/capture/berlin_sights.csv. For every sight, the
zoom-14 OpenFreeMap vector tile around the approximate position (and, if needed,
its neighbours) is searched for a point of interest, peak or square whose name
matches one of the aliases; the best match within 2 km gives the exact position
(© OpenStreetMap contributors, ODbL): not a stop, entrance or sign if anything
else matches, then earlier aliases first, exact names before partial ones,
classes fitting the category, the nearest. Aliases "@manual" keep the given
position (open areas without a point, e.g. Tempelhofer Feld, or fountains the
tiles lack; positions from Wikidata). Sights without a match are left out and
reported. Tiles are cached in --cache. With --districts (a GeoJSON of named
polygons), every sight gets the district it lies in.

Usage: pip install mapbox-vector-tile
       python3 Tools/capture/locate_sights.py Tools/capture/berlin_sights.csv \
           --cache build-sights --districts App/MapQuest/Resources/Berlin/berlin-districts.geojson \
           App/MapQuest/Resources/Berlin/berlin-sights.json
"""
import argparse
import csv
import gzip
import json
import math
import pathlib
import sys
import urllib.request

import mapbox_vector_tile

TILEJSON = "https://tiles.openfreemap.org/planet"
ZOOM = 14
USER_AGENT = "MapQuest-tools/1 (sight list build)"
# Features that only carry a sight's name: used only if nothing else matches.
SECONDARY = {"bus", "railway", "entrance", "bicycle_rental", "parking", "fuel", "information", "school", "ferry_terminal"}
# Categories whose OSM classes are preferred when several features share a name.
PREFERRED = {
    "church": {"place_of_worship"},
    "museum": {"museum", "art_gallery"},
    "palace": {"castle", "attraction", "museum"},
    "park": {"park", "garden"},
    "zoo": {"zoo", "attraction"},
    "culture": {"theatre", "music", "cinema", "art_gallery"},
    "memorial": {"monument", "attraction", "museum"},
    "monument": {"monument", "attraction"},
    "fountain": {"attraction", "art_gallery"},
    "market": {"grocery", "marketplace", "attraction"},
    "government": {"town_hall", "office"},
}


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "gzip"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    return gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data


def tile_of(lat: float, lon: float):
    n = 1 << ZOOM
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y


def to_geo(tx: int, ty: int, px: float, py: float, extent: int):
    n = 1 << ZOOM
    lon = (tx + px / extent) / n * 360 - 180
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (ty + py / extent) / n))))
    return lat, lon


def distance(a, b) -> float:
    dy = (a[0] - b[0]) * 111_320
    dx = (a[1] - b[1]) * 111_320 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def normalize(name: str) -> str:
    return name.casefold().replace("–", "-").replace(" ", " ").strip()


class Tiles:
    def __init__(self, cache: pathlib.Path):
        self.cache = cache
        cache.mkdir(parents=True, exist_ok=True)
        self.template = json.loads(fetch(TILEJSON))["tiles"][0]
        self.decoded = {}

    def features(self, x: int, y: int):
        """(lat, lon, names, class, layer) of named point and line features of a tile."""
        if (x, y) in self.decoded:
            return self.decoded[(x, y)]
        path = self.cache / f"{ZOOM}_{x}_{y}.mvt"
        if not path.exists():
            url = self.template.replace("{z}", str(ZOOM)).replace("{x}", str(x)).replace("{y}", str(y))
            path.write_bytes(fetch(url))
        tile = mapbox_vector_tile.decode(path.read_bytes(), default_options={"y_coord_down": True})
        result = []
        for layer in ("poi", "mountain_peak", "aerodrome_label", "transportation_name"):
            data = tile.get(layer)
            if not data:
                continue
            extent = data["extent"]
            for feature in data["features"]:
                props = feature["properties"]
                names = {normalize(str(props[k])) for k in ("name", "name:de", "name_de", "name_int") if props.get(k)}
                if not names:
                    continue
                geometry = feature["geometry"]
                if geometry["type"] == "Point":
                    points = [geometry["coordinates"]]
                elif geometry["type"] == "MultiPoint":
                    points = geometry["coordinates"]
                elif geometry["type"] == "LineString":
                    points = geometry["coordinates"]
                elif geometry["type"] == "MultiLineString":
                    points = [p for line in geometry["coordinates"] for p in line]
                else:
                    continue
                # Lines (squares): the vertex nearest to their centre.
                cx = sum(p[0] for p in points) / len(points)
                cy = sum(p[1] for p in points) / len(points)
                px, py = min(points, key=lambda p: (p[0] - cx) ** 2 + (p[1] - cy) ** 2)
                if not (0 <= px <= extent and 0 <= py <= extent):
                    continue
                lat, lon = to_geo(x, y, px, py, extent)
                result.append((lat, lon, names, props.get("class"), layer))
        self.decoded[(x, y)] = result
        return result


def locate(tiles: Tiles, sight: dict):
    approx = (float(sight["lat"]), float(sight["lon"]))
    aliases = [normalize(a) for a in sight["aliases"].split("|") if a.strip()]
    preferred = PREFERRED.get(sight["category"], set())
    tx, ty = tile_of(*approx)
    candidates = []
    best = None
    for ring in (0, 1):
        for dx in range(-ring, ring + 1):
            for dy in range(-ring, ring + 1):
                if max(abs(dx), abs(dy)) != ring:
                    continue
                for lat, lon, names, cls, layer in tiles.features(tx + dx, ty + dy):
                    exact = any(a in names for a in aliases)
                    partial = not exact and any(a in n for a in aliases for n in names if len(a) >= 8)
                    if not (exact or partial):
                        continue
                    if layer == "transportation_name" and sight["category"] != "square":
                        continue
                    d = distance(approx, (lat, lon))
                    if d > 2_000:
                        continue
                    index = min(i for i, a in enumerate(aliases) if a in names or any(a in n for n in names))
                    score = (1 if cls in SECONDARY else 0, index, 0 if exact else 1, 0 if cls in preferred else 1, d)
                    candidates.append((score, lat, lon, sorted(names)[0], cls, layer, d))
        # A stop or sign only: look into the neighbouring tiles as well.
        if candidates and min(candidates)[0][0] == 0:
            return min(candidates)
        best = min(candidates) if candidates else None
    return best


def inside(point, ring) -> bool:
    """Even-odd rule; point and ring as (lon, lat)."""
    x, y = point
    result = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            result = not result
    return result


def read_districts(path: pathlib.Path):
    """(name, polygons) per feature; a polygon is a list of rings (exterior first)."""
    result = []
    for feature in json.loads(path.read_text(encoding="utf-8"))["features"]:
        geometry = feature["geometry"]
        polygons = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
        result.append((feature["properties"]["name"], polygons))
    return result


def district_of(districts, lat: float, lon: float):
    for name, polygons in districts:
        for rings in polygons:
            if inside((lon, lat), rings[0]) and not any(inside((lon, lat), hole) for hole in rings[1:]):
                return name
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sights", type=pathlib.Path)
    parser.add_argument("--cache", type=pathlib.Path, required=True)
    parser.add_argument("--districts", type=pathlib.Path, help="GeoJSON of the city's districts (named polygons)")
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    tiles = Tiles(args.cache)
    districts = read_districts(args.districts) if args.districts else []
    with open(args.sights, encoding="utf-8") as f:
        rows = list(csv.DictReader(f, delimiter=";"))
    found, missing = [], []
    for row in rows:
        if row["aliases"].strip() == "@manual":
            print(f"{row['id']:28}      –  manual position")
            found.append({
                "id": row["id"], "name": row["name"], "category": row["category"],
                "latitude": float(row["lat"]), "longitude": float(row["lon"]), "radius": int(row["radius"]),
            })
            continue
        match = locate(tiles, row)
        if not match:
            missing.append(row["id"])
            print(f"MISSING {row['id']}: {row['name']}", file=sys.stderr)
            continue
        _, lat, lon, osm_name, cls, layer, d = match
        print(f"{row['id']:28} {d:6.0f} m  {layer}/{cls}: {osm_name}")
        found.append({
            "id": row["id"], "name": row["name"], "category": row["category"],
            "latitude": round(lat, 6), "longitude": round(lon, 6), "radius": int(row["radius"]),
        })
    for sight in found:
        if districts:
            sight["district"] = district_of(districts, sight["latitude"], sight["longitude"])
            if not sight["district"]:
                print(f"OUTSIDE the districts: {sight['id']}", file=sys.stderr)
    document = {
        "source": "Curated list (Tools/capture/berlin_sights.csv), positions from OpenStreetMap "
                  "points of interest via OpenFreeMap vector tiles (© OpenStreetMap contributors, ODbL); "
                  "positions marked @manual from Wikidata (CC0)",
        "sights": found,
    }
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(found)} sights located, {len(missing)} missing: {', '.join(missing)}")


if __name__ == "__main__":
    main()
