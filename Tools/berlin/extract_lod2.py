"""Extracts building heights from Berlin's official 3D building models (LoD2).

Source: "3D-Gebäudemodelle im Level of Detail 2 (LoD 2)", Senatsverwaltung für
Stadtentwicklung, Bauen und Wohnen Berlin, https://gdi.berlin.de/data/a_lod2/atom
(Datenlizenz Deutschland – Zero – 2.0): ~925 CityGML tiles of 1 × 1 km in
ETRS89/UTM 33N with DHHN2016 heights.

Every bldg:Building and bldg:BuildingPart with its own ground surface becomes one
JSON line:  {"id": <gml:id>, "h": <height above ground, m>, "z": <ground elevation, m>,
             "r": [[lon, lat], ...]}  (one line per ground polygon, WGS84).
The height is bldg:measuredHeight, or roof top minus ground if it is missing.

Usage: pip install lxml pyproj
       python3 Tools/berlin/extract_lod2.py --cache <download dir> lod2.jsonl
       (or pass CityGML zip files instead of --cache to process only those)
"""
import argparse
import json
import pathlib
import re
import sys
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

from lxml import etree
from pyproj import Transformer

FEED = "https://gdi.berlin.de/data/a_lod2/atom/0.atom"
BLDG = "{http://www.opengis.net/citygml/building/1.0}"
GML = "{http://www.opengis.net/gml}"
TO_WGS84 = Transformer.from_crs("EPSG:25833", "EPSG:4326", always_xy=True)


def tile_urls() -> list:
    feed = urllib.request.urlopen(FEED, timeout=60).read().decode("utf-8")
    return sorted(set(re.findall(r'href="(https://gdi\.berlin\.de/data/a_lod2/atom/LoD2_\d+_\d+\.zip)"', feed)))


def download(url: str, cache: pathlib.Path) -> pathlib.Path:
    path = cache / url.rsplit("/", 1)[1]
    if not path.exists() or path.stat().st_size == 0:
        tmp = path.with_suffix(".part")
        urllib.request.urlretrieve(url, tmp)
        tmp.rename(path)
    return path


def pos_list(element) -> list:
    values = [float(v) for v in element.text.split()]
    return [values[i:i + 3] for i in range(0, len(values) - 2, 3)]


def own_surfaces(element, kind: str) -> list:
    """posLists of `kind` surfaces that belong to this element (not to its parts)."""
    rings = []
    for bounded in element.findall(f"{BLDG}boundedBy"):
        for surface in bounded.findall(f"{BLDG}{kind}"):
            for poslist in surface.iter(f"{GML}posList"):
                rings.append(pos_list(poslist))
    return rings


def records(element) -> list:
    grounds = own_surfaces(element, "GroundSurface")
    if not grounds:
        return []
    z = min(p[2] for ring in grounds for p in ring)
    measured = element.find(f"{BLDG}measuredHeight")
    height = float(measured.text) if measured is not None and measured.text else None
    if height is None:
        roofs = own_surfaces(element, "RoofSurface")
        if not roofs:
            return []
        height = max(p[2] for ring in roofs for p in ring) - z
    if height <= 0:
        return []
    out = []
    for ring in grounds:
        if len(ring) < 4:
            continue
        lons, lats = TO_WGS84.transform([p[0] for p in ring], [p[1] for p in ring])
        out.append({
            "id": element.get(f"{GML}id"),
            "h": round(height, 2),
            "z": round(z, 2),
            "r": [[round(lon, 7), round(lat, 7)] for lon, lat in zip(lons, lats)],
        })
    return out


def process(path: pathlib.Path, out) -> int:
    count = 0
    with zipfile.ZipFile(path) as archive:
        for info in archive.infolist():
            if not info.filename.lower().endswith((".xml", ".gml")):
                continue
            with archive.open(info) as stream:
                for _, element in etree.iterparse(stream, events=("end",), tag=(f"{BLDG}Building", f"{BLDG}BuildingPart"), huge_tree=True):
                    for record in records(element):
                        out.write(json.dumps(record, separators=(",", ":")))
                        out.write("\n")
                        count += 1
                    if element.tag == f"{BLDG}Building":
                        element.clear()
                        while element.getprevious() is not None:
                            del element.getparent()[0]
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", type=pathlib.Path, help="download all tiles into this directory")
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("tiles", nargs="*", type=pathlib.Path, help="process only these zip files")
    args = parser.parse_args()
    paths = args.tiles
    if not paths:
        if not args.cache:
            parser.error("either --cache or tile files are required")
        args.cache.mkdir(parents=True, exist_ok=True)
        urls = tile_urls()
        print(f"{len(urls)} LoD2 tiles", flush=True)
        with ThreadPoolExecutor(max_workers=8) as pool:
            paths = list(pool.map(lambda u: download(u, args.cache), urls))
        print("downloaded", flush=True)
    total = 0
    with open(args.output, "w", encoding="utf-8") as out:
        for i, path in enumerate(paths):
            total += process(path, out)
            if (i + 1) % 50 == 0:
                print(f"{i + 1}/{len(paths)} tiles, {total} footprints", flush=True)
    print(f"{total} LoD2 footprints with heights -> {args.output}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
