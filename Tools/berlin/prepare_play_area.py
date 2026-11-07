"""Builds MapQuest's Berlin play area from the official district geometries.

Source: the 12 Berlin districts ("Bezirke") published by the Amt für Statistik
Berlin-Brandenburg (CC BY 3.0 DE), merged from localities and converted to
GeoJSON by https://github.com/m-hoerz/berlin-shapes.

Outputs (WGS84 GeoJSON, simplified to ~2 m):
  App/MapQuest/Resources/Berlin/berlin-districts.geojson  (12 features: name, code)
  App/MapQuest/Resources/Berlin/berlin-boundary.geojson   (1 feature: the city outline)

Usage: python3 Tools/berlin/prepare_play_area.py   (requires: pip install shapely)
"""
import json
import math
import pathlib
import urllib.request

import shapely
from shapely.geometry import mapping, shape
from shapely.ops import unary_union

SOURCE_URL = "https://raw.githubusercontent.com/m-hoerz/berlin-shapes/master/berliner-bezirke.geojson"
ROOT = pathlib.Path(__file__).resolve().parents[2]
CACHE = ROOT / "Tools" / ".cache"
OUT = ROOT / "App" / "MapQuest" / "Resources" / "Berlin"
ATTRIBUTION = "Bezirksgrenzen: Amt für Statistik Berlin-Brandenburg, CC BY 3.0 DE (via github.com/m-hoerz/berlin-shapes)"

# ~2 m in degrees of latitude; longitudes are scaled per feature below.
SIMPLIFY_METERS = 2.0


def download() -> dict:
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / "berliner-bezirke.geojson"
    if not path.exists():
        urllib.request.urlretrieve(SOURCE_URL, path)
    return json.loads(path.read_text(encoding="utf-8"))


def to_local(lat0: float):
    """Equirectangular metres around lat0, so simplification tolerances are metric."""
    scale = [111_320 * math.cos(math.radians(lat0)), 111_320]
    fwd = lambda g: shapely.transform(g, lambda c: c * scale)
    inv = lambda g: shapely.transform(g, lambda c: c / scale)
    return fwd, inv


def round_coords(geometry: dict, digits: int = 6) -> dict:
    def r(c):
        if isinstance(c[0], (int, float)):
            return [round(c[0], digits), round(c[1], digits)]
        return [r(x) for x in c]
    return {"type": geometry["type"], "coordinates": r(geometry["coordinates"])}


def main() -> None:
    source = download()
    fwd, inv = to_local(52.5)
    districts = []
    for feature in source["features"]:
        props = feature["properties"]
        geom = fwd(shape(feature["geometry"])).buffer(0)
        districts.append((props["spatial_alias"], props["spatial_name"], geom))

    # Close slivers between neighbouring districts, then shrink back.
    outline = unary_union([g.buffer(0.5) for _, _, g in districts]).buffer(-0.5)
    outline = outline.simplify(SIMPLIFY_METERS, preserve_topology=True)

    OUT.mkdir(parents=True, exist_ok=True)
    features = []
    total = 0.0
    for name, code, geom in sorted(districts, key=lambda d: d[1]):
        simplified = geom.simplify(SIMPLIFY_METERS, preserve_topology=True)
        total += geom.area
        features.append({
            "type": "Feature",
            "properties": {"name": name, "code": code},
            "geometry": round_coords(mapping(inv(simplified))),
        })
        print(f"{code} {name:28s} {geom.area / 1e6:7.2f} km²")
    print(f"sum of districts: {total / 1e6:.1f} km², outline: {outline.area / 1e6:.1f} km²")

    (OUT / "berlin-districts.geojson").write_text(json.dumps({
        "type": "FeatureCollection", "attribution": ATTRIBUTION, "features": features,
    }, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    (OUT / "berlin-boundary.geojson").write_text(json.dumps({
        "type": "FeatureCollection", "attribution": ATTRIBUTION, "features": [{
            "type": "Feature",
            "properties": {"name": "Berlin"},
            "geometry": round_coords(mapping(inv(outline))),
        }],
    }, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


if __name__ == "__main__":
    main()
