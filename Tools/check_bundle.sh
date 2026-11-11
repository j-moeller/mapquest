#!/usr/bin/env bash
# Checks that a built MapQuest.app contains the bundled city data.
#   Tools/check_bundle.sh path/to/MapQuest.app
# Without an argument the newest simulator build in Xcode's DerivedData is checked.
set -euo pipefail
APP="${1:-$(find ~/Library/Developer/Xcode/DerivedData -path "*iphonesimulator/MapQuest.app" -maxdepth 6 -type d | head -1)}"
echo "$APP"
missing=0
for f in berlin-boundary.geojson berlin-districts.geojson demo-track.mqtrack berlin-terrain.dem berlin-buildings.sqlite.deflate \
         braunschweig-boundary.geojson braunschweig-districts.geojson braunschweig-terrain.dem braunschweig-buildings.sqlite.deflate \
         peine-boundary.geojson peine-terrain.dem peine-buildings.sqlite.deflate \
         berlin-sights.json berlin-sight-info.json berlin-sight-history.json; do
    test -e "$APP/$f" || { echo "missing $f"; missing=1; }
done
[ "$missing" = 0 ] && echo "all bundled data present"
exit "$missing"
