"""A municipality's outline from BKG's VG250 (official administrative areas).

Source: "Verwaltungsgebiete 1:250 000 (Ebenen)", © GeoBasis-DE / BKG,
Datenlizenz Deutschland – Namensnennung – 2.0, GeoPackage in ETRS89/UTM 32N:
https://daten.gdz.bkg.bund.de/produkte/vg/vg250_ebenen_0101/aktuell/vg250_01-01.utm32s.gpkg.ebenen.zip

For towns whose OpenStreetMap boundary is not at hand. VG250 is generalised for
1:250 000 (boundaries within roughly 100 m), good for the outline, coverage
statistics and the download region. Land areas only (GF = 4); no districts.

Optionally also writes the outline grown by --margin metres (for fetching data
around the town and marking it complete).

Usage: pip install pyproj shapely
       python3 Tools/cities/vg250_boundary.py DE_VG250.gpkg --ags 03157006 --name Peine \
           --out App/MapQuest/Resources/Peine/peine-boundary.geojson \
           [--margin 1000 --margin-out build-peine/area.geojson]
"""
import argparse
import json
import pathlib
import sqlite3
import struct

import shapely
from pyproj import Transformer


def gpkg_geometry(blob: bytes):
    """Decodes a GeoPackage geometry blob (header + WKB)."""
    if blob[:2] != b"GP":
        raise ValueError("not a GeoPackage geometry")
    flags = blob[3]
    envelope = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}[(flags >> 1) & 0b111]
    return shapely.from_wkb(blob[8 + envelope:])


def to_wgs84(geometry):
    to_geo = Transformer.from_crs("EPSG:25832", "EPSG:4326", always_xy=True)
    return shapely.transform(geometry, lambda c: list(zip(*to_geo.transform(c[:, 0], c[:, 1]))))


def write(path: pathlib.Path, name: str, geometry):
    geometry = shapely.set_precision(geometry, 1e-7)
    feature = {"type": "Feature", "properties": {"name": name}, "geometry": shapely.geometry.mapping(geometry)}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"type": "FeatureCollection", "features": [feature]}, separators=(",", ":")), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("gpkg", type=pathlib.Path)
    parser.add_argument("--ags", required=True, help="Amtlicher Gemeindeschlüssel, e.g. 03157006 (Peine)")
    parser.add_argument("--name", required=True)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--margin", type=float, default=0)
    parser.add_argument("--margin-out", type=pathlib.Path)
    args = parser.parse_args()

    db = sqlite3.connect(args.gpkg)
    rows = db.execute("SELECT geom, GEN, BEZ FROM vg250_gem WHERE AGS = ? AND GF = 4", (args.ags,)).fetchall()
    if not rows:
        raise SystemExit(f"no municipality with AGS {args.ags}")
    utm = shapely.union_all([gpkg_geometry(row[0]) for row in rows])
    print(f"{rows[0][2]} {rows[0][1]}: {utm.area / 1e6:.1f} km², {shapely.get_num_coordinates(utm)} points")
    write(args.out, args.name, to_wgs84(utm))
    if args.margin_out:
        grown = utm.buffer(args.margin, join_style="mitre").simplify(10)
        write(args.margin_out, f"{args.name} + {args.margin:.0f} m", to_wgs84(grown))
        print(f"with {args.margin:.0f} m margin: {grown.area / 1e6:.1f} km²")


if __name__ == "__main__":
    main()
