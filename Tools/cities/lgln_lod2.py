"""Building heights for a city in Lower Saxony from LGLN's LoD2 models.

Source: "3D-Gebäudemodelle LoD2", Landesamt für Geoinformation und
Landesvermessung Niedersachsen (LGLN), OpenGeoData (Datenlizenz Deutschland –
Namensnennung – 2.0): CityGML tiles of 1 × 1 km in ETRS89/UTM 32N, served as
https://lod2.s3.eu-de.cloud-object-storage.appdomain.cloud/LoD2_32_<E km>_<N km>_1_ni.gml

Downloads every tile intersecting the city boundary (missing tiles are
skipped), extracts footprints with heights exactly like Tools/berlin/extract_lod2.py
(one JSON line per ground polygon) and deletes each tile after processing.

Usage: pip install lxml pyproj shapely
       python3 Tools/cities/lgln_lod2.py --boundary braunschweig-boundary.geojson --cache lod2-cache lod2.jsonl
"""
import argparse
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

import shapely
from pyproj import Transformer
from shapely.geometry import box, shape

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "berlin"))
import extract_lod2  # noqa: E402

BUCKET = "https://lod2.s3.eu-de.cloud-object-storage.appdomain.cloud"


def tiles(boundary_path: pathlib.Path):
    """UTM 32 kilometre tiles (E, N) intersecting the boundary."""
    features = json.loads(boundary_path.read_text(encoding="utf-8"))["features"]
    city = shapely.union_all([shape(f["geometry"]) for f in features])
    to_utm = Transformer.from_crs("EPSG:4326", "EPSG:25832", always_xy=True)
    utm = shapely.transform(city, lambda c: list(zip(*to_utm.transform(c[:, 0], c[:, 1]))))
    minx, miny, maxx, maxy = utm.bounds
    result = []
    for e in range(int(minx // 1000), int(maxx // 1000) + 1):
        for n in range(int(miny // 1000), int(maxy // 1000) + 1):
            if utm.intersects(box(e * 1000, n * 1000, (e + 1) * 1000, (n + 1) * 1000)):
                result.append((e, n))
    return result


def download(e: int, n: int, cache: pathlib.Path, attempts: int = 6):
    url = f"{BUCKET}/LoD2_32_{e}_{n}_1_ni.gml"
    path = cache / f"LoD2_32_{e}_{n}_1_ni.gml"
    for attempt in range(attempts):
        try:
            urllib.request.urlretrieve(url, path)
            return path
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None  # no buildings modelled there
            if error.code < 500 or attempt == attempts - 1:
                raise
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            if attempt == attempts - 1:
                raise
        time.sleep(2 ** (attempt + 1))
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--boundary", type=pathlib.Path, required=True)
    parser.add_argument("--cache", type=pathlib.Path, required=True)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    extract_lod2.set_source_crs(25832)
    wanted = tiles(args.boundary)
    print(f"{len(wanted)} LoD2 tiles intersect the boundary", flush=True)
    total = processed = missing = 0
    with open(args.output, "w", encoding="utf-8") as out, ThreadPoolExecutor(max_workers=6) as pool:
        futures = [pool.submit(download, e, n, args.cache) for e, n in wanted]
        for future in as_completed(futures):
            path = future.result()
            if path is None:
                missing += 1
                continue
            total += extract_lod2.process(path, out)
            path.unlink()
            processed += 1
            if processed % 25 == 0:
                print(f"{processed} tiles, {total} footprints", flush=True)
    print(f"{total} LoD2 footprints from {processed} tiles ({missing} without data) -> {args.output}", flush=True)


if __name__ == "__main__":
    main()
