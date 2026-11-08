"""Turns LoD2 footprints (Tools/berlin/extract_lod2.py) into building elements
for `mapquest-import buildings`, for places without an OpenStreetMap extract.

Every LoD2 building and building part becomes a building with its own ground
polygon and measured height (`mapquest:height_source=lod2`), so towers modelled
as separate parts keep their height. Duplicates (the same gml:id in two tiles)
are dropped; IDs are numbered from 1.

Usage: python3 Tools/cities/lod2_buildings.py lod2.jsonl buildings.jsonl
"""
import json
import sys


def main(lod2_path: str, out_path: str) -> None:
    seen = set()
    written = skipped = 0
    with open(lod2_path, encoding="utf-8") as f, open(out_path, "w", encoding="utf-8") as out:
        for line in f:
            record = json.loads(line)
            ring = record["r"]
            key = (record.get("id"), ring[0][0], ring[0][1])
            if key in seen:
                continue
            seen.add(key)
            if len(ring) < 4 or record["h"] < 1:
                skipped += 1
                continue
            if ring[0] != ring[-1]:
                ring = ring + [ring[0]]
            written += 1
            element = {
                "type": "way",
                "id": written,
                "tags": {"building": "yes", "height": f"{record['h']:.1f}", "mapquest:height_source": "lod2"},
                "geometry": [{"lat": lat, "lon": lon} for lon, lat in ring],
            }
            out.write(json.dumps(element, separators=(",", ":")))
            out.write("\n")
    print(f"{written} buildings, {skipped} skipped (lower than 1 m or degenerate), {len(seen) - written - skipped} duplicates")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: lod2_buildings.py LOD2.jsonl OUT.jsonl")
    main(sys.argv[1], sys.argv[2])
