"""Gives OpenStreetMap building outlines the heights of Berlin's official LoD2 models.

Inputs:  buildings.jsonl  (Overpass-style elements from extract_buildings.py)
         lod2.jsonl       (footprints with heights from extract_lod2.py)
Output:  the elements with `height` set from LoD2 and `mapquest:height_source=lod2`.

Rule: the LoD2 parts that lie mostly (≥ 50 %) inside an OSM footprint all belong
to it, and the tallest of them gives the height – so towers modelled as separate
parts (Rotes Rathaus, Berliner Dom, Funkturm) are not lost. If no part lies mostly
inside, the part covering most of the footprint (≥ 30 % of it) is used. An explicit
OSM `height` tag that is taller wins (antennas, buildings newer than the survey).

OSM footprints are kept (stable IDs, consistent with on-demand OSM downloads at the
city border); only their heights change.

Usage: pip install shapely
       python3 Tools/berlin/apply_lod2_heights.py buildings.jsonl lod2.jsonl out.jsonl
"""
import json
import sys

import numpy as np
import shapely

MIN_OVERLAP = 0.3
MOSTLY_INSIDE = 0.5


def osm_height(tags: dict):
    """The explicit OSM height in metres, if it is a plain number (optionally with "m")."""
    value = (tags.get("height") or tags.get("building:height") or "").strip().lower()
    value = value.removesuffix("m").strip().replace(",", ".")
    try:
        return float(value)
    except ValueError:
        return None


def osm_footprint(element: dict):
    def ring(points):
        coords = [(p["lon"], p["lat"]) for p in points if p]
        return coords if len(coords) >= 4 else None

    if element["type"] == "way":
        outer = ring(element.get("geometry", []))
        return shapely.Polygon(outer) if outer else None
    outers = [ring(m.get("geometry", [])) for m in element.get("members", []) if m.get("role") != "inner"]
    polygons = [shapely.Polygon(o) for o in outers if o]
    return shapely.MultiPolygon(polygons) if polygons else None


def main(buildings_path: str, lod2_path: str, out_path: str) -> None:
    lod2_heights, lod2_polygons = [], []
    with open(lod2_path, encoding="utf-8") as f:
        for line in f:
            record = json.loads(line)
            lod2_heights.append(record["h"])
            lod2_polygons.append(shapely.Polygon(record["r"]))
    lod2 = shapely.make_valid(np.array(lod2_polygons, dtype=object))
    heights = np.array(lod2_heights)
    tree = shapely.STRtree(lod2)
    print(f"{len(lod2)} LoD2 footprints indexed", flush=True)

    elements = [json.loads(line) for line in open(buildings_path, encoding="utf-8")]
    footprints = np.array([osm_footprint(e) for e in elements], dtype=object)
    valid = np.array([g is not None for g in footprints])
    footprints[valid] = shapely.make_valid(footprints[valid])
    indices = np.nonzero(valid)[0]
    pairs = tree.query(footprints[indices], predicate="intersects")
    osm_index = indices[pairs[0]]
    lod2_index = pairs[1]
    overlap = shapely.area(shapely.intersection(footprints[osm_index], lod2[lod2_index]))
    print(f"{len(osm_index)} candidate pairs", flush=True)

    part_area = shapely.area(lod2[lod2_index])
    inside = overlap >= MOSTLY_INSIDE * np.maximum(part_area, 1e-18)
    # Tallest part mostly inside each footprint.
    tallest_inside = np.full(len(elements), -np.inf)
    np.maximum.at(tallest_inside, osm_index[inside], heights[lod2_index[inside]])
    # Fallback: the part with the largest overlap.
    best_overlap = np.zeros(len(elements))
    best_height = np.full(len(elements), np.nan)
    order = np.argsort(overlap)  # later (larger) overlaps overwrite smaller ones
    best_overlap[osm_index[order]] = overlap[order]
    best_height[osm_index[order]] = heights[lod2_index[order]]

    areas = np.zeros(len(elements))
    areas[valid] = shapely.area(footprints[valid])
    assigned = 0
    with open(out_path, "w", encoding="utf-8") as out:
        for i, element in enumerate(elements):
            if np.isfinite(tallest_inside[i]):
                height = tallest_inside[i]
            elif areas[i] > 0 and best_overlap[i] >= MIN_OVERLAP * areas[i]:
                height = best_height[i]
            else:
                height = np.nan
            tags = element.setdefault("tags", {})
            tagged = osm_height(tags)
            if height >= 2 and not (tagged is not None and tagged > height):
                tags["height"] = f"{height:.1f}"
                tags["mapquest:height_source"] = "lod2"
                assigned += 1
            out.write(json.dumps(element, ensure_ascii=False, separators=(",", ":")))
            out.write("\n")
    print(f"LoD2 heights for {assigned} of {len(elements)} buildings ({assigned / max(len(elements), 1) * 100:.1f} %) -> {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
