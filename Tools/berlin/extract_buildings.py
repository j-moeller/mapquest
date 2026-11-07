"""Extracts building outlines from an OpenStreetMap file (PBF or XML) as
Overpass-style JSON elements, one per line (JSON Lines).

The output is read by `swift run mapquest-import buildings`, which applies the
same height rules as the app (OSMBuildingHeights) and writes the SQLite
building database. Closed ways become `way` elements; multipolygon relations
become `relation` elements whose members are already assembled rings.

Usage:
  pip install osmium
  python3 Tools/berlin/extract_buildings.py berlin-latest.osm.pbf buildings.jsonl

OSM data © OpenStreetMap contributors, ODbL 1.0.
"""
import json
import sys

import osmium


def is_building(tags: dict) -> bool:
    if "building" in tags:
        return tags["building"] != "no"
    return tags.get("man_made") == "tower" and "height" in tags


def ring(nodes) -> list:
    return [{"lat": round(n.lat, 7), "lon": round(n.lon, 7)} for n in nodes]


class BuildingWriter(osmium.SimpleHandler):
    def __init__(self, out):
        super().__init__()
        self.out = out
        self.ways = 0
        self.relations = 0

    def area(self, area):
        tags = {tag.k: tag.v for tag in area.tags}
        if not is_building(tags):
            return
        members = []
        for outer in area.outer_rings():
            members.append({"type": "way", "role": "outer", "geometry": ring(outer)})
            for inner in area.inner_rings(outer):
                members.append({"type": "way", "role": "inner", "geometry": ring(inner)})
        if not members:
            return
        if area.from_way():
            element = {"type": "way", "id": area.orig_id(), "tags": tags, "geometry": members[0]["geometry"]}
            self.ways += 1
        else:
            element = {"type": "relation", "id": area.orig_id(), "tags": {**tags, "type": "multipolygon"}, "members": members}
            self.relations += 1
        self.out.write(json.dumps(element, ensure_ascii=False, separators=(",", ":")))
        self.out.write("\n")


def main(source: str, target: str) -> None:
    with open(target, "w", encoding="utf-8") as out:
        writer = BuildingWriter(out)
        writer.apply_file(source, locations=True)
    print(f"{writer.ways} building ways, {writer.relations} building multipolygons -> {target}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
