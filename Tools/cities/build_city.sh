#!/usr/bin/env bash
# Builds the bundled data of a city in Lower Saxony (docs/06-braunschweig-data.md):
# outline and districts (OpenStreetMap), buildings (OpenStreetMap footprints
# with heights from LGLN's LoD2 models) and the terrain model (LGLN DGM1).
# LoD2 heights and terrain are best effort: without them the buildings keep
# their OSM heights and the city has no terrain model.
#
# Writes App/MapQuest/Resources/<Name>/<id>-{boundary,districts}.geojson,
# <id>-buildings.sqlite.deflate and <id>-terrain.dem. Run from the repository
# root; work files go to ./build-<id>.
#
#   Tools/cities/build_city.sh --id braunschweig --name Braunschweig --admin-level 6 \
#       --bbox 10.30,52.12,10.75,52.42 \
#       --viewshed "Burgplatz (street)@52.26420,10.52360"
#   Tools/cities/build_city.sh --id peine --name Peine --admin-level 8 \
#       --bbox 10.08,52.22,10.40,52.42 \
#       --viewshed "Marktplatz (street)@52.32030,10.23370"
#
# OpenStreetMap input: by default the Geofabrik extract of Lower Saxony is
# downloaded and cut to --bbox (needs osmium-tool). --osm FILE uses an existing
# extract instead (PBF or OSM XML, e.g. from the Overpass API) that contains the
# city's boundary relation, its districts and all buildings.
#
# Requirements: python3 with osmium lxml pyproj shapely numpy rasterio
# (pip install ...), sqlite3, a Swift toolchain, and osmium-tool for the
# Geofabrik download.
set -euo pipefail

ID="" NAME="" LEVEL="" BBOX="" OSM="" PYTHON="${PYTHON:-python3}"
VIEWSHEDS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --id) ID="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --admin-level) LEVEL="$2"; shift 2 ;;
        --bbox) BBOX="$2"; shift 2 ;;
        --osm) OSM="$(realpath "$2")"; shift 2 ;;
        --viewshed) VIEWSHEDS+=("$2"); shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [ -z "$ID" ] || [ -z "$NAME" ] || [ -z "$LEVEL" ] || { [ -z "$BBOX" ] && [ -z "$OSM" ]; }; then
    echo "usage: $0 --id ID --name NAME --admin-level N (--bbox W,S,E,N | --osm FILE) [--viewshed LABEL@LAT,LON[,ALT]]..." >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/App/MapQuest/Resources/$NAME"
WORK="$ROOT/build-$ID"
mkdir -p "$OUT" "$WORK"
cd "$ROOT"

echo "== OpenStreetMap input"
if [ -z "$OSM" ]; then
    OSM="$WORK/city.osm.pbf"
    if [ ! -s "$OSM" ]; then
        curl -fsSL -o "$WORK/niedersachsen.osm.pbf" https://download.geofabrik.de/europe/germany/niedersachsen-latest.osm.pbf
        osmium extract --strategy smart -S types=boundary,multipolygon -b "$BBOX" "$WORK/niedersachsen.osm.pbf" -o "$OSM" --overwrite
        rm "$WORK/niedersachsen.osm.pbf"
    fi
fi
ls -la "$OSM"

echo "== Outline and districts (OSM)"
"$PYTHON" Tools/cities/extract_osm_areas.py "$OSM" \
    --name "$NAME" --id "$ID" --admin-level "$LEVEL" --district-levels 9,10 --out "$OUT"

echo "== OSM buildings"
"$PYTHON" Tools/berlin/extract_buildings.py "$OSM" "$WORK/buildings.jsonl"

echo "== LoD2 heights (LGLN)"
SOURCE="OpenStreetMap contributors (ODbL), extract of $(date -u +%F)"
if "$PYTHON" Tools/cities/lgln_lod2.py --boundary "$OUT/$ID-boundary.geojson" --cache "$WORK/lod2-cache" "$WORK/lod2.jsonl" \
        && [ -s "$WORK/lod2.jsonl" ]; then
    "$PYTHON" Tools/berlin/apply_lod2_heights.py "$WORK/buildings.jsonl" "$WORK/lod2.jsonl" "$WORK/buildings-final.jsonl"
    SOURCE="$SOURCE; heights: LoD2 LGLN Niedersachsen (dl-de/by-2-0)"
else
    echo "LoD2 heights unavailable: keeping the OSM heights" >&2
    cp "$WORK/buildings.jsonl" "$WORK/buildings-final.jsonl"
fi

echo "== Building database"
rm -f "$WORK/$ID-buildings.sqlite"
(cd MapQuestKit && swift run -c release mapquest-import buildings \
    --output "$WORK/$ID-buildings.sqlite" \
    --complete-inside "$OUT/$ID-boundary.geojson" \
    --source "$SOURCE" \
    "$WORK/buildings-final.jsonl")

echo "== Statistics (height source 0 = OSM height tag, 1 = OSM levels, 2 = estimated, 3 = LoD2)"
sqlite3 -header -column "$WORK/$ID-buildings.sqlite" \
    "SELECT height_source, COUNT(*) AS buildings, ROUND(AVG(height), 1) AS avg_height FROM buildings GROUP BY height_source;"
sqlite3 -header -column "$WORK/$ID-buildings.sqlite" \
    "SELECT name, height, height_source FROM buildings WHERE name IS NOT NULL ORDER BY height DESC LIMIT 10;"
sqlite3 "$WORK/$ID-buildings.sqlite" "SELECT COUNT(*) || ' complete zoom-14 tiles' FROM downloaded_tiles;"

echo "== Terrain (LGLN DGM1)"
"$PYTHON" Tools/cities/lgln_terrain.py --boundary "$OUT/$ID-boundary.geojson" --cache "$WORK/dgm-cache" "$OUT/$ID-terrain.dem" \
    || echo "Terrain unavailable: the city has no terrain model" >&2

if [ ${#VIEWSHEDS[@]} -gt 0 ]; then
    echo "== Viewshed check on real buildings"
    (cd MapQuestKit && swift run -c release mapquest-import viewshed --database "$WORK/$ID-buildings.sqlite" "${VIEWSHEDS[@]}")
fi

echo "== Compress for the app bundle"
"$PYTHON" Tools/cities/deflate.py "$WORK/$ID-buildings.sqlite" "$OUT/$ID-buildings.sqlite.deflate"
ls -la "$OUT"
