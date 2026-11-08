#!/usr/bin/env bash
# Builds Berlin's bundled building database (docs/03-berlin-data.md):
# OpenStreetMap footprints (Geofabrik Berlin extract) with heights from Berlin's
# official LoD2 building models, compressed to
# App/MapQuest/Resources/Berlin/berlin-buildings.sqlite.deflate.
# Run from the repository root; work files go to ./build-berlin.
#
# Requirements: python3 with osmium lxml pyproj shapely numpy (pip install ...),
# sqlite3 and a Swift toolchain.
set -euo pipefail
PYTHON="${PYTHON:-python3}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/build-berlin"
mkdir -p "$WORK"
cd "$ROOT"

echo "== OpenStreetMap extract (Geofabrik)"
[ -s "$WORK/berlin.osm.pbf" ] || curl -fsSL -o "$WORK/berlin.osm.pbf" https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf

echo "== OSM buildings"
"$PYTHON" Tools/berlin/extract_buildings.py "$WORK/berlin.osm.pbf" "$WORK/buildings.jsonl"

echo "== LoD2 heights (Geoportal Berlin)"
"$PYTHON" Tools/berlin/extract_lod2.py --cache "$WORK/lod2-cache" "$WORK/lod2.jsonl"
"$PYTHON" Tools/berlin/apply_lod2_heights.py "$WORK/buildings.jsonl" "$WORK/lod2.jsonl" "$WORK/buildings-lod2.jsonl"

echo "== Building database"
rm -f "$WORK/berlin-buildings.sqlite"
(cd MapQuestKit && swift run -c release mapquest-import buildings \
    --output "$WORK/berlin-buildings.sqlite" \
    --complete-inside "$ROOT/App/MapQuest/Resources/Berlin/berlin-boundary.geojson" \
    --source "OpenStreetMap contributors (ODbL), Geofabrik extract of $(date -u +%F); heights: LoD2 Berlin (dl-de/zero-2-0)" \
    "$WORK/buildings-lod2.jsonl")

echo "== Statistics (height source 0 = OSM height tag, 1 = OSM levels, 2 = estimated, 3 = LoD2)"
sqlite3 -header -column "$WORK/berlin-buildings.sqlite" \
    "SELECT height_source, COUNT(*) AS buildings, ROUND(AVG(height), 1) AS avg_height FROM buildings GROUP BY height_source;"
sqlite3 -header -column "$WORK/berlin-buildings.sqlite" \
    "SELECT name, height, height_source FROM buildings WHERE name IS NOT NULL ORDER BY height DESC LIMIT 10;"

echo "== Viewshed check on real buildings"
(cd MapQuestKit && swift run -c release mapquest-import viewshed --database "$WORK/berlin-buildings.sqlite" \
    "Alexanderplatz (street)@52.52190,13.41320" \
    "Unter den Linden (street)@52.51700,13.38880" \
    "Kreuzberg side street@52.49720,13.42190" \
    "Tempelhofer Feld@52.47400,13.40300" \
    "Fernsehturm viewing deck@52.52082,13.40940,238" \
    "Park Inn rooftop (125 m)@52.52310,13.41290,160")

echo "== Compress for the app bundle"
"$PYTHON" Tools/cities/deflate.py "$WORK/berlin-buildings.sqlite" App/MapQuest/Resources/Berlin/berlin-buildings.sqlite.deflate
