"""Extracts a city's outline and its districts from OpenStreetMap.

The city is the administrative boundary relation with the given name and
admin_level; its districts are the boundary relations of the first of the
given district levels with a plausible count (5–60) whose interior points lie
inside the city. Both are simplified to ~2 m and written as GeoJSON (WGS84):

  <out>/<id>-boundary.geojson   (1 feature: name)
  <out>/<id>-districts.geojson  (features: name, admin_level)

Usage: pip install osmium shapely
       python3 Tools/cities/extract_osm_areas.py city.osm.pbf --name Braunschweig --id braunschweig \\
           --admin-level 6 --district-levels 9,10 --out App/MapQuest/Resources/Braunschweig

OSM data © OpenStreetMap contributors, ODbL 1.0.
"""
import argparse
import json
import math
import pathlib
import sys

import osmium
import shapely
from shapely.prepared import prep
from shapely import wkb
from shapely.geometry import mapping

SIMPLIFY_METERS = 2.0


class Boundaries(osmium.SimpleHandler):
    def __init__(self, levels):
        super().__init__()
        self.levels = set(levels)
        self.factory = osmium.geom.WKBFactory()
        self.found = []  # (admin_level, name, geometry)

    def area(self, area):
        tags = {tag.k: tag.v for tag in area.tags}
        if area.from_way() or tags.get("boundary") != "administrative":
            return
        level = tags.get("admin_level")
        if level not in self.levels or not tags.get("name"):
            return
        try:
            geometry = wkb.loads(self.factory.create_multipolygon(area), hex=True)
        except Exception as error:  # broken relation: skip it
            print(f"skipping {tags.get('name')}: {error}", file=sys.stderr)
            return
        self.found.append((level, tags["name"], geometry))


def simplify(geometry, latitude):
    """Simplifies with a tolerance of SIMPLIFY_METERS (degrees scaled per axis)."""
    k = math.cos(math.radians(latitude))
    scaled = shapely.transform(geometry, lambda c: c * [k, 1])
    simplified = scaled.simplify(SIMPLIFY_METERS / 111_320, preserve_topology=True)
    return shapely.transform(simplified, lambda c: c / [k, 1])


def write(path: pathlib.Path, features):
    path.write_text(json.dumps({"type": "FeatureCollection", "features": features}, separators=(",", ":")), encoding="utf-8")
    print(f"{path}: {len(features)} features")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pbf", type=pathlib.Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--admin-level", default="6")
    parser.add_argument("--district-levels", default="9,10")
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args()

    district_levels = args.district_levels.split(",")
    handler = Boundaries([args.admin_level] + district_levels)
    handler.apply_file(str(args.pbf), locations=True)

    cities = [g for level, name, g in handler.found if level == args.admin_level and name == args.name]
    if not cities:
        sys.exit(f"no boundary named {args.name} at admin_level {args.admin_level}")
    city = max(cities, key=lambda g: g.area)
    latitude = city.centroid.y
    args.out.mkdir(parents=True, exist_ok=True)
    write(args.out / f"{args.id}-boundary.geojson", [{
        "type": "Feature", "properties": {"name": args.name},
        "geometry": mapping(simplify(city, latitude)),
    }])

    inside = prep(city.buffer(0.001))
    for level in district_levels:
        districts = [(name, g) for l, name, g in handler.found
                     if l == level and inside.contains(g.representative_point())]
        print(f"admin_level {level}: {len(districts)} districts")
        if 5 <= len(districts) <= 60:
            write(args.out / f"{args.id}-districts.geojson", [{
                "type": "Feature", "properties": {"name": name, "admin_level": level},
                "geometry": mapping(simplify(g.intersection(city), latitude)),
            } for name, g in sorted(districts)])
            return
    print("no plausible district level found; districts omitted", file=sys.stderr)


if __name__ == "__main__":
    main()
