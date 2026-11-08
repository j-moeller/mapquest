"""A city's terrain model from LGLN's 1 m elevation model (DGM1).

Source: "Digitales Geländemodell DGM1", LGLN OpenGeoData (Datenlizenz
Deutschland – Namensnennung – 2.0): GeoTIFF tiles of 1 × 1 km in ETRS89/UTM 32N,
listed in the bucket https://dgm1.s3.eu-de.cloud-object-storage.appdomain.cloud
as L<lot>/<kind>/dgm1_32_<E km>_<N km>_1_ni_<year>.tif.

Like Tools/berlin/prepare_terrain.py: 1 m heights are averaged into 25 m UTM
cells, resampled bilinearly onto a ~30 m latitude/longitude grid covering the
city and written in MapQuest's MQDEM001 format (see GridTerrain).

Usage: pip install numpy pyproj rasterio shapely
       python3 Tools/cities/lgln_terrain.py --boundary braunschweig-boundary.geojson --cache dgm-cache braunschweig-terrain.dem
"""
import argparse
import json
import pathlib
import re
import struct
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import rasterio
import shapely
from pyproj import Transformer
from shapely.geometry import shape

BUCKET = "https://dgm1.s3.eu-de.cloud-object-storage.appdomain.cloud"
CELL = 25.0
LAT_STEP = 0.00027   # ≈ 30 m
LON_STEP = 0.00045   # ≈ 30 m at 52° N
NODATA = -32768
KEY = re.compile(r"dgm1_32_(\d+)_(\d+)_1_ni_(\d{4})\.tif$")


def fetch(url: str, attempts: int = 6) -> str:
    for attempt in range(attempts):
        try:
            return urllib.request.urlopen(url, timeout=60).read().decode("utf-8")
        except Exception:
            if attempt == attempts - 1:
                raise
            time.sleep(2 ** (attempt + 1))
    return ""


def list_keys(prefix: str):
    """All keys below a prefix (paged, 1000 per request)."""
    keys, marker = [], ""
    while True:
        query = urllib.parse.urlencode({"max-keys": 1000, "marker": marker, "prefix": prefix})
        xml = fetch(f"{BUCKET}/?{query}")
        page = re.findall(r"<Key>([^<]+)</Key>", xml)
        keys += page
        if "<IsTruncated>true</IsTruncated>" not in xml or not page:
            return keys
        marker = page[-1]


def list_tiles(wanted):
    """Keys of the newest tile for every wanted (E, N), preferring full tiles.

    The bucket holds one folder per delivery lot (L<lot>/…); they are listed in parallel.
    """
    xml = fetch(f"{BUCKET}/?{urllib.parse.urlencode({'delimiter': '/', 'max-keys': 1000})}")
    lots = [p for p in re.findall(r"<Prefix>([^<]*)</Prefix>", xml) if p]
    best = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        for keys in pool.map(list_keys, lots):
            for key in keys:
                m = KEY.search(key)
                if not m:
                    continue
                tile = (int(m.group(1)), int(m.group(2)))
                if tile not in wanted:
                    continue
                rank = (int(m.group(3)), "Vollkacheln" in key)
                if tile not in best or rank > best[tile][0]:
                    best[tile] = (rank, key)
    print(f"listed {len(lots)} lots", flush=True)
    return {tile: key for tile, (_, key) in best.items()}


def download(key: str, cache: pathlib.Path, attempts: int = 6) -> pathlib.Path:
    path = cache / key.rsplit("/", 1)[1]
    if path.exists() and path.stat().st_size > 0:
        return path
    for attempt in range(attempts):
        try:
            urllib.request.urlretrieve(f"{BUCKET}/{urllib.parse.quote(key)}", path)
            return path
        except Exception:
            if attempt == attempts - 1:
                raise
            time.sleep(2 ** (attempt + 1))
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--boundary", type=pathlib.Path, required=True)
    parser.add_argument("--cache", type=pathlib.Path, required=True)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)

    features = json.loads(args.boundary.read_text(encoding="utf-8"))["features"]
    city = shapely.union_all([shape(f["geometry"]) for f in features])
    west, south, east, north = city.bounds
    south, west, north, east = south - 0.005, west - 0.008, north + 0.005, east + 0.008
    to_utm = Transformer.from_crs("EPSG:4326", "EPSG:25832", always_xy=True)
    xs, ys = to_utm.transform([west, east, west, east], [south, south, north, north])
    e0, e1, n0, n1 = int(min(xs) // 1000), int(max(xs) // 1000), int(min(ys) // 1000), int(max(ys) // 1000)
    wanted = {(e, n) for e in range(e0, e1 + 1) for n in range(n0, n1 + 1)}
    keys = list_tiles(wanted)
    print(f"{len(keys)} of {len(wanted)} DGM1 tiles available", flush=True)

    x0, y0 = e0 * 1000.0, n0 * 1000.0
    nx, ny = int((e1 - e0 + 1) * 1000 / CELL), int((n1 - n0 + 1) * 1000 / CELL)
    total = np.zeros((ny, nx))
    count = np.zeros((ny, nx))
    with ThreadPoolExecutor(max_workers=6) as pool:
        paths = list(pool.map(lambda key: download(key, args.cache), keys.values()))
    for i, path in enumerate(paths):
        with rasterio.open(path) as src:
            data = src.read(1).astype(np.float64)
            valid = np.isfinite(data)
            if src.nodata is not None:
                valid &= data != src.nodata
            valid &= data > -1000
            left, top = src.transform.c, src.transform.f
            res = src.transform.a
        rows, cols = data.shape
        # Pixel centres → 25 m cells of the city grid.
        cx = ((left + (np.arange(cols) + 0.5) * res - x0) / CELL).astype(np.int64)
        cy = ((top - (np.arange(rows) + 0.5) * res - y0) / CELL).astype(np.int64)
        gx, gy = np.meshgrid(cx, cy)
        ok = valid & (gx >= 0) & (gx < nx) & (gy >= 0) & (gy < ny)
        np.add.at(total, (gy[ok], gx[ok]), data[ok])
        np.add.at(count, (gy[ok], gx[ok]), 1)
        path.unlink()
        if (i + 1) % 25 == 0:
            print(f"aggregated {i + 1}/{len(paths)} tiles", flush=True)
    with np.errstate(invalid="ignore", divide="ignore"):
        utm = np.where(count > 0, total / count, np.nan)

    rows = int(round((north - south) / LAT_STEP)) + 1
    cols = int(round((east - west) / LON_STEP)) + 1
    lon_grid, lat_grid = np.meshgrid(west + np.arange(cols) * LON_STEP, south + np.arange(rows) * LAT_STEP)
    ux, uy = to_utm.transform(lon_grid, lat_grid)
    fx, fy = (ux - x0) / CELL - 0.5, (uy - y0) / CELL - 0.5
    ix, iy = np.floor(fx).astype(np.int64), np.floor(fy).astype(np.int64)
    tx, ty = fx - ix, fy - iy
    inside = (ix >= 0) & (iy >= 0) & (ix + 1 < nx) & (iy + 1 < ny)
    ixc, iyc = np.clip(ix, 0, nx - 2), np.clip(iy, 0, ny - 2)
    value = (utm[iyc, ixc] * (1 - tx) * (1 - ty) + utm[iyc, ixc + 1] * tx * (1 - ty)
             + utm[iyc + 1, ixc] * (1 - tx) * ty + utm[iyc + 1, ixc + 1] * tx * ty)
    value = np.where(inside, value, np.nan)
    decimetres = np.where(np.isnan(value), NODATA, np.round(value * 10)).astype("<i2")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "wb") as out:
        out.write(b"MQDEM001")
        out.write(struct.pack("<4d", south, west, LAT_STEP, LON_STEP))
        out.write(struct.pack("<2i", rows, cols))
        out.write(decimetres.tobytes())
    known = value[~np.isnan(value)]
    print(f"{args.output}: {rows} × {cols} cells, {np.isnan(value).mean() * 100:.1f} % no data, "
          f"elevation {known.min():.1f}–{known.max():.1f} m, median {np.median(known):.1f} m", flush=True)


if __name__ == "__main__":
    main()
