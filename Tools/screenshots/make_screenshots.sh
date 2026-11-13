#!/usr/bin/env bash
# App Store-style mockups of MapQuest's main screens (1290 × 2796, the 6.7" size),
# made from the app's own code and data: the map drawn by MapQuestCore from
# OpenFreeMap tiles with the fog of war over the demo explorer's discovered area
# (plus a few traced walks), and sights, history, achievements, stations and the
# remembrance guide from the bundled data. Screens are HTML/CSS approximations of
# the SwiftUI views; for the store itself, take real ones from the simulator.
#
# Needs: Swift (MapQuestKit), Python 3, Node with Playwright and its Chromium, and the
# z14 vector tiles of central Berlin in build-sights/ (Tools/capture/locate_sights.py
# caches them there). Writes build-screenshots/ (store-*.png framed, *.png screens).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$PWD/${1:-build-screenshots}"
shift || true  # further arguments: only these screens (e.g. 01-map)
TOOLS="$PWD/Tools/screenshots"
mkdir -p "$OUT/assets"
export MQ_SHOTS_DIR="$OUT"

# Icons: Material Symbols Rounded (filled), the stand-in for SF Symbols.
if [ ! -s "$OUT/assets/material-symbols.woff2" ]; then
  css=$(curl -fsS -A "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/120 Safari/537.36" \
    "https://fonts.googleapis.com/css2?family=Material+Symbols+Rounded:opsz,wght,FILL,GRAD@24,500,1,0")
  curl -fsS "$(grep -o 'https://[^)]*' <<<"$css" | head -1)" -o "$OUT/assets/material-symbols.woff2"
fi

# The map and the discovered area (MapQuestCore's renderer and discovery engine).
python3 "$TOOLS/walks.py" "$OUT/walks.txt"
read -r MINX MINY MAXX MAXY < <(cd "$TOOLS" && python3 -c "from common import export_bounds; print(*export_bounds())")
(cd MapQuestKit && MQ_MOCKUP_OUT="$OUT" MQ_WALKS="$OUT/walks.txt" MQ_TILES="$PWD/../build-sights" \
  MQ_MINX=$MINX MQ_MINY=$MINY MQ_MAXX=$MAXX MQ_MAXY=$MAXY swift test --filter MockupMapExportTests)
(cd "$TOOLS" && python3 make_map.py)
node "$TOOLS/shoot.js" "$OUT/map-fog.html" "$OUT/map-fog.png" 430 932 3

# The screens and their App Store pages.
(cd "$TOOLS" && python3 screens.py "$@")
echo "Screens in $OUT: store-*.png (App Store pages) and the bare screens."
