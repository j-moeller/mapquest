"""Builds MapQuest's terrain model of Berlin from the official 1 m elevation model.

Source: ATKIS® DGM (1 m grid), Senatsverwaltung für Stadtentwicklung, Bauen und
Wohnen Berlin, via https://gdi.berlin.de/data/dgm1/atom (Datenlizenz Deutschland –
Zero – 2.0). ~300 tiles of 2 × 2 km as XYZ text in ETRS89/UTM 33N (EPSG:25833),
heights in DHHN2016 (≈ metres above sea level, like Core Location's `altitude`).

The 1 m points are averaged into 25 m cells in UTM, then resampled bilinearly
onto a regular latitude/longitude grid (~30 m) and written as
App/MapQuest/Resources/Berlin/berlin-terrain.dem:

    bytes 0–7    magic "MQDEM001"
    float64 × 4  south latitude, west longitude, latitude step, longitude step (degrees)
    int32 × 2    rows, columns
    int16 × r·c  elevation in decimetres, row 0 = south, column 0 = west; -32768 = no data
    (all little-endian)

Usage: pip install numpy pyproj
       python3 Tools/berlin/prepare_terrain.py --cache <download dir>
"""
import argparse
import pathlib
import re
import struct
import sys
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from pyproj import Transformer

FEED = "https://gdi.berlin.de/data/dgm1/atom/0.atom"
ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "App" / "MapQuest" / "Resources" / "Berlin" / "berlin-terrain.dem"

CELL = 25.0                 # UTM aggregation cell (m)
LAT_STEP = 0.00027          # ≈ 30 m
LON_STEP = 0.00045          # ≈ 30 m at 52.5° N
BBOX = (52.3272, 13.0703, 52.6688, 13.7501)  # south, west, north, east (feed's georss box)
NODATA = -32768


def tile_urls() -> list:
    feed = urllib.request.urlopen(FEED, timeout=60).read().decode("utf-8")
    return sorted(set(re.findall(r'href="(https://gdi\.berlin\.de/data/dgm1/atom/DGM1_\d+_\d+\.zip)"', feed)))


def download(url: str, cache: pathlib.Path) -> pathlib.Path:
    path = cache / url.rsplit("/", 1)[1]
    if not path.exists() or path.stat().st_size == 0:
        tmp = path.with_suffix(".part")
        urllib.request.urlretrieve(url, tmp)
        tmp.rename(path)
    return path


def read_tile(path: pathlib.Path) -> np.ndarray:
    with zipfile.ZipFile(path) as z:
        text = z.read(z.infolist()[0])
    values = np.array(text.split(), dtype=np.float64)
    return values.reshape(-1, 3)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", required=True, type=pathlib.Path, help="directory for the downloaded tiles")
    parser.add_argument("--output", type=pathlib.Path, default=OUT)
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)

    urls = tile_urls()
    print(f"{len(urls)} DGM1 tiles", flush=True)
    with ThreadPoolExecutor(max_workers=4) as pool:
        paths = list(pool.map(lambda u: download(u, args.cache), urls))
    print("downloaded", flush=True)

    # Aggregate into 25 m UTM cells.
    tiles = [tuple(int(v) for v in re.findall(r"DGM1_(\d+)_(\d+)", p.name)[0]) for p in paths]
    x0 = min(t[0] for t in tiles) * 1000.0
    y0 = min(t[1] for t in tiles) * 1000.0
    x1 = (max(t[0] for t in tiles) + 2) * 1000.0
    y1 = (max(t[1] for t in tiles) + 2) * 1000.0
    nx, ny = int((x1 - x0) / CELL), int((y1 - y0) / CELL)
    total = np.zeros(ny * nx)
    count = np.zeros(ny * nx)
    for i, path in enumerate(paths):
        xyz = read_tile(path)
        ix = ((xyz[:, 0] - x0) / CELL).astype(np.int64)
        iy = ((xyz[:, 1] - y0) / CELL).astype(np.int64)
        ok = (ix >= 0) & (ix < nx) & (iy >= 0) & (iy < ny)
        flat = iy[ok] * nx + ix[ok]
        total += np.bincount(flat, weights=xyz[ok, 2], minlength=ny * nx)
        count += np.bincount(flat, minlength=ny * nx)
        if (i + 1) % 25 == 0:
            print(f"aggregated {i + 1}/{len(paths)} tiles", flush=True)
    with np.errstate(invalid="ignore", divide="ignore"):
        utm = np.where(count > 0, total / count, np.nan).reshape(ny, nx)

    # Resample onto the latitude/longitude grid (bilinear in the UTM cell grid).
    south, west, north, east = BBOX
    rows = int(round((north - south) / LAT_STEP)) + 1
    cols = int(round((east - west) / LON_STEP)) + 1
    lats = south + np.arange(rows) * LAT_STEP
    lons = west + np.arange(cols) * LON_STEP
    lon_grid, lat_grid = np.meshgrid(lons, lats)
    to_utm = Transformer.from_crs("EPSG:4326", "EPSG:25833", always_xy=True)
    ux, uy = to_utm.transform(lon_grid, lat_grid)
    fx = (ux - x0) / CELL - 0.5
    fy = (uy - y0) / CELL - 0.5
    ix = np.floor(fx).astype(np.int64)
    iy = np.floor(fy).astype(np.int64)
    tx, ty = fx - ix, fy - iy
    valid = (ix >= 0) & (iy >= 0) & (ix + 1 < nx) & (iy + 1 < ny)
    ixc, iyc = np.clip(ix, 0, nx - 2), np.clip(iy, 0, ny - 2)
    v00, v10 = utm[iyc, ixc], utm[iyc, ixc + 1]
    v01, v11 = utm[iyc + 1, ixc], utm[iyc + 1, ixc + 1]
    value = (v00 * (1 - tx) * (1 - ty) + v10 * tx * (1 - ty) + v01 * (1 - tx) * ty + v11 * tx * ty)
    value = np.where(valid, value, np.nan)
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
    sys.exit(main())
