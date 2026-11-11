#!/usr/bin/env python3
"""3D models of the sights' buildings from Berlin's official LoD2 building models.

Source: "3D-Gebäudemodelle im Level of Detail 2 (LoD 2)", Senatsverwaltung für
Stadtentwicklung, Bauen und Wohnen Berlin, https://gdi.berlin.de/data/a_lod2/atom
(Datenlizenz Deutschland – Zero – 2.0): CityGML tiles of 1 × 1 km, ETRS89/UTM 33N,
DHHN2016 heights; walls and roofs with their real roof shapes.

For every sight (Tools/capture/locate_sights.py output) its building is the
OpenStreetMap building outline containing the sight's position (OpenFreeMap
zoom-14 vector tile; for building categories – museum, palace, church, culture,
stadium, landmark, viewpoint – also the nearest within 12 m). Palaces, churches
and stadiums are ensembles: every OSM building within the sight's extent counts
(palace wings, a stadium's stands, the old church tower next to the new church).
LoD2 splits large landmarks into several buildings, so the model is every LoD2
building lying mostly (≥ 50 %) inside that outline – or, without an outline, the
LoD2 buildings containing the position (ensembles: within its extent). LoD2 is
generalised: domes and spires end where the model's roof does (the Berliner Dom
at 43 m). Sights without a building
of their own (parks, squares, monuments in the open) get no model; the app then
shows their surroundings only.

Every wall and roof polygon (with holes) is triangulated (earcut, in its own
plane; triangles wound like the ring, so their normals point outwards) and moved
into the app's local frame around the sight: x east, z south
(Web Mercator metres at the sight, like LocalFrame), y up from the lowest ground
point of the model. Output per sight: <out>/sight-<id>.mqm (raw DEFLATE of the
MQM1 format, see MapQuestCore/Capture/SightModel.swift):

  "MQM1", uint32 vertex count, uint32 index count, uint32 footprint ring count,
  vertices (int16 x, y, z in decimetres), one uint8 per vertex (0 wall, 1 roof),
  uint32 indices (triangles), footprint rings (uint32 point count, int16 x, z dm).

Usage: pip install lxml pyproj shapely mapbox-earcut numpy
       python3 Tools/capture/sight_models.py App/MapQuest/Resources/Berlin/berlin-sights.json \
           --cache build-sights/lod2 App/MapQuest/Resources/Berlin/SightModels
"""
import argparse
import json
import math
import pathlib
import struct
import sys
import time
import urllib.error
import urllib.request
import zipfile
import zlib

import mapbox_earcut
import mapbox_vector_tile
import numpy as np
from lxml import etree
from pyproj import Transformer
import shapely
from shapely.geometry import Point, Polygon

BASE = "https://gdi.berlin.de/data/a_lod2/atom"
TO_UTM = Transformer.from_crs("EPSG:4326", "EPSG:25833", always_xy=True)
TO_WGS84 = Transformer.from_crs("EPSG:25833", "EPSG:4326", always_xy=True)
WORLD = float(1 << 32)
CIRCUMFERENCE = 40_075_016.68557849
BUILDING_CATEGORIES = {"museum", "palace", "church", "culture", "stadium", "landmark", "viewpoint"}
# Ensembles: every building within the sight's extent belongs to it (palace wings,
# a stadium's stands, a church's old tower next to the new one).
ENSEMBLE_CATEGORIES = {"palace", "church", "stadium"}


def download(name: str, cache: pathlib.Path) -> pathlib.Path | None:
    path = cache / name
    if path.exists() and path.stat().st_size > 0:
        return path
    for attempt in range(6):
        try:
            urllib.request.urlretrieve(f"{BASE}/{name}", path.with_suffix(".part"))
            path.with_suffix(".part").rename(path)
            return path
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            if error.code < 500 or attempt == 5:
                raise
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            if attempt == 5:
                raise
        time.sleep(2 ** (attempt + 1))
    return None


def polygons_of(element, kinds: tuple) -> list:
    """(kind, exterior, [holes]) of the surfaces of `kind` belonging to this element itself."""
    result = []
    for bounded in element.findall("{*}boundedBy"):
        for surface in bounded:
            kind = etree.QName(surface).localname
            if kind not in kinds:
                continue
            for polygon in surface.iter("{*}Polygon"):
                rings = []
                for ring_kind in ("exterior", "interior"):
                    for ring in polygon.findall(f"{{*}}{ring_kind}"):
                        poslist = ring.find(".//{*}posList")
                        if poslist is None or not poslist.text:
                            continue
                        v = [float(x) for x in poslist.text.split()]
                        rings.append((ring_kind, [v[i:i + 3] for i in range(0, len(v) - 2, 3)]))
                exterior = [r for k, r in rings if k == "exterior"]
                if exterior:
                    result.append((kind, exterior[0], [r for k, r in rings if k == "interior"]))
    return result


class Tile:
    """The buildings of a tile: id, ground polygons (2D, UTM), surfaces of the building and its parts."""

    def __init__(self, path: pathlib.Path):
        self.buildings = []
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if not info.filename.lower().endswith((".xml", ".gml")):
                    continue
                for _, element in etree.iterparse(archive.open(info), events=("end",), tag="{*}Building", huge_tree=True):
                    members = [element] + list(element.iter("{*}BuildingPart"))
                    grounds, surfaces = [], []
                    for member in members:
                        for _, exterior, holes in polygons_of(member, ("GroundSurface",)):
                            try:
                                polygon = Polygon([(p[0], p[1]) for p in exterior], [[(p[0], p[1]) for p in h] for h in holes]).buffer(0)
                            except Exception:
                                continue
                            if not polygon.is_empty:
                                grounds.append((polygon, min(p[2] for p in exterior)))
                        surfaces += polygons_of(member, ("WallSurface", "RoofSurface", "ClosureSurface"))
                    if grounds and surfaces:
                        self.buildings.append({"grounds": grounds, "surfaces": surfaces})
                    element.clear()
                    while element.getprevious() is not None:
                        del element.getparent()[0]


OSM_TILES = None  # (template, cache directory)


def osm_outline(lat: float, lon: float, category: str, radius: float):
    """The OSM building outline (UTM) at a position from the zoom-14 vector tile."""
    template, cache = OSM_TILES
    zoom = 14
    n = 1 << zoom
    tx = int((lon + 180) / 360 * n)
    ty = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    path = cache / f"{zoom}_{tx}_{ty}.mvt"
    if not path.exists():
        url = template.replace("{z}", str(zoom)).replace("{x}", str(tx)).replace("{y}", str(ty))
        request = urllib.request.Request(url, headers={"User-Agent": "MapQuest-tools/1", "Accept-Encoding": "gzip"})
        data = urllib.request.urlopen(request, timeout=60).read()
        path.write_bytes(zlib.decompress(data, 16 + zlib.MAX_WBITS) if data[:2] == b"\x1f\x8b" else data)
    tile = mapbox_vector_tile.decode(path.read_bytes(), default_options={"y_coord_down": True})
    layer = tile.get("building")
    if not layer:
        return None
    extent = layer["extent"]

    def to_utm(ring):
        lons = [(tx + x / extent) / n * 360 - 180 for x, _ in ring]
        lats = [math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (ty + y / extent) / n)))) for _, y in ring]
        es, ns = TO_UTM.transform(lons, lats)
        return list(zip(es, ns))

    polygons = []
    for feature in layer["features"]:
        geometry = feature["geometry"]
        parts = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"] if geometry["type"] == "MultiPolygon" else []
        for part in parts:
            try:
                polygon = Polygon(to_utm(part[0]), [to_utm(h) for h in part[1:]]).buffer(0)
            except Exception:
                continue
            if not polygon.is_empty:
                polygons.append(polygon)
    east, north = TO_UTM.transform(lon, lat)
    point = Point(east, north)
    containing = [p for p in polygons if p.contains(point)]
    if category in ENSEMBLE_CATEGORIES:
        containing += [p for p in polygons if p.distance(point) <= radius and p not in containing]
    if containing:
        return shapely.union_all(containing)
    if category in BUILDING_CATEGORIES:
        near = sorted((p.distance(point), i) for i, p in enumerate(polygons))
        if near and near[0][0] <= 12:
            return polygons[near[0][1]]
    return None


def local_frame(lat: float, lon: float):
    """Web Mercator metres around a position (east, south), as MapQuestCore's LocalFrame."""
    def project(lat_, lon_):
        x = (lon_ + 180) / 360 * WORLD
        r = math.radians(lat_)
        y = (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * WORLD
        return x, y
    ox, oy = project(lat, lon)
    meters_per_unit = CIRCUMFERENCE / WORLD * math.cos(math.radians(lat))

    def convert(east: np.ndarray, north: np.ndarray):
        lons, lats = TO_WGS84.transform(east, north)
        xs, ys = [], []
        for lo, la in zip(np.atleast_1d(lons), np.atleast_1d(lats)):
            x, y = project(la, lo)
            xs.append((x - ox) * meters_per_unit)
            ys.append((y - oy) * meters_per_unit)
        return np.array(xs), np.array(ys)
    return convert


def triangulate(points: np.ndarray, holes: list) -> np.ndarray:
    """Triangles (index triples into points + holes) of a planar 3D polygon."""
    rings = [points] + holes
    allpoints = np.vstack(rings)
    # Newell normal; project onto the plane of the two other axes.
    normal = np.zeros(3)
    for i in range(len(points)):
        a, b = points[i], points[(i + 1) % len(points)]
        normal += [(a[1] - b[1]) * (a[2] + b[2]), (a[2] - b[2]) * (a[0] + b[0]), (a[0] - b[0]) * (a[1] + b[1])]
    drop = int(np.argmax(np.abs(normal)))
    keep = [i for i in range(3) if i != drop]
    flat = allpoints[:, keep].astype(np.float64)
    ends = np.cumsum([len(r) for r in rings]).astype(np.uint32)
    triangles = mapbox_earcut.triangulate_float64(flat, ends).reshape(-1, 3)
    # Wind every triangle like the ring (CityGML: counter-clockwise seen from outside),
    # so that triangle normals point outwards.
    for t in triangles:
        a, b, c = allpoints[t[0]], allpoints[t[1]], allpoints[t[2]]
        if np.dot(np.cross(b - a, c - a), normal) < 0:
            t[1], t[2] = t[2], t[1]
    return triangles


def build(sight: dict, tiles: dict, cache: pathlib.Path):
    east, north = TO_UTM.transform(sight["longitude"], sight["latitude"])
    point = Point(east, north)
    names = {(int(east // 1000) + dx, int(north // 1000) + dy)
             for dx in (-1, 0, 1) for dy in (-1, 0, 1)
             if (east + dx * 150) // 1000 == int(east // 1000) + dx and (north + dy * 150) // 1000 == int(north // 1000) + dy}
    candidates = []
    for e, n in sorted(names):
        key = f"LoD2_{e}_{n}.zip"
        if key not in tiles:
            path = download(key, cache)
            tiles[key] = Tile(path) if path else None
        if tiles[key]:
            candidates += tiles[key].buildings
    outline = osm_outline(sight["latitude"], sight["longitude"], sight["category"], sight["radius"])
    if outline is not None:
        grown = outline.buffer(1)
        chosen = []
        for building in candidates:
            area = sum(g.area for g, _ in building["grounds"])
            inside = sum(g.intersection(grown).area for g, _ in building["grounds"])
            if area > 0 and inside >= 0.5 * area:
                chosen.append(building)
    elif sight["category"] in ENSEMBLE_CATEGORIES:
        circle = point.buffer(sight["radius"])
        chosen = [b for b in candidates if any(g.intersects(circle) for g, _ in b["grounds"])]
    else:
        chosen = [b for b in candidates if any(g.contains(point) for g, _ in b["grounds"])]
    if not chosen:
        return None

    ground = min(z for b in chosen for _, z in b["grounds"])
    convert = local_frame(sight["latitude"], sight["longitude"])
    vertices, classes, indices, footprints = [], [], [], []
    for building in chosen:
        for kind, exterior, holes in building["surfaces"]:
            rings = [np.array(exterior[:-1] if exterior[0] == exterior[-1] else exterior)]
            rings += [np.array(h[:-1] if h[0] == h[-1] else h) for h in holes]
            if len(rings[0]) < 3:
                continue
            try:
                triangles = triangulate(rings[0], rings[1:])
            except Exception:
                continue
            if len(triangles) == 0:
                continue
            points = np.vstack(rings)
            xs, zs = convert(points[:, 0], points[:, 1])
            base = len(vertices)
            for x, z, h in zip(xs, zs, points[:, 2] - ground):
                vertices.append((x, h, z))
                classes.append(1 if kind == "RoofSurface" else 0)
            indices += [base + int(i) for i in triangles.flatten()]
        for polygon, _ in building["grounds"]:
            ring = np.array(polygon.exterior.coords) if polygon.geom_type == "Polygon" else None
            if ring is None:
                continue
            xs, zs = convert(ring[:, 0], ring[:, 1])
            footprints.append(list(zip(xs, zs)))
    if not indices:
        return None

    def dm(value: float) -> int:
        return max(-32767, min(32767, int(round(value * 10))))

    data = bytearray(b"MQM1")
    data += struct.pack("<III", len(vertices), len(indices), len(footprints))
    for x, y, z in vertices:
        data += struct.pack("<hhh", dm(x), dm(y), dm(z))
    data += bytes(classes)
    data += struct.pack(f"<{len(indices)}I", *indices)
    for ring in footprints:
        data += struct.pack("<I", len(ring))
        for x, z in ring:
            data += struct.pack("<hh", dm(x), dm(z))
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    height = max(v[1] for v in vertices)
    return c.compress(bytes(data)) + c.flush(), len(chosen), len(indices) // 3, height


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sights", type=pathlib.Path)
    parser.add_argument("--cache", type=pathlib.Path, required=True)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--osm-cache", type=pathlib.Path, default=pathlib.Path("build-sights"),
                        help="zoom-14 OpenFreeMap tiles (cached by locate_sights.py)")
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    global OSM_TILES
    request = urllib.request.Request("https://tiles.openfreemap.org/planet", headers={"User-Agent": "MapQuest-tools/1"})
    tilejson = json.loads(urllib.request.urlopen(request, timeout=60).read())
    OSM_TILES = (tilejson["tiles"][0], args.osm_cache)
    args.output.mkdir(parents=True, exist_ok=True)
    sights = json.loads(args.sights.read_text(encoding="utf-8"))["sights"]
    tiles, total, without = {}, 0, []
    for sight in sights:
        result = build(sight, tiles, args.cache)
        target = args.output / f"sight-{sight['id']}.mqm"
        if not result:
            without.append(sight["id"])
            if target.exists():
                target.unlink()
            print(f"{sight['id']:28} no building of its own")
            continue
        data, buildings, triangles, height = result
        target.write_bytes(data)
        total += len(data)
        print(f"{sight['id']:28} {buildings:3} buildings {triangles:6} triangles {height:6.1f} m  {len(data) / 1024:7.1f} KB", flush=True)
    print(f"{len(sights) - len(without)} models, {total / 1e6:.1f} MB; without: {', '.join(without)}")


if __name__ == "__main__":
    main()
