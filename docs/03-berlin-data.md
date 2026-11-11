# MapQuest – Berlin data

Berlin is the first city with bundled data (the fog of war works everywhere). This page lists every dataset the app uses for
Berlin, where it comes from, and how to regenerate it.

## 2D

| Data | Source | Licence | File |
|---|---|---|---|
| Base map | OpenStreetMap vector tiles from OpenFreeMap (OpenMapTiles schema), drawn on the device without labels | ODbL 1.0 (© OpenStreetMap contributors), © OpenMapTiles; OpenFreeMap: free, no key | – (loaded on demand, cached on the device) |
| District boundaries (12 Bezirke) | Amt für Statistik Berlin-Brandenburg, merged from localities by [m-hoerz/berlin-shapes](https://github.com/m-hoerz/berlin-shapes) | CC BY 3.0 DE | `App/MapQuest/Resources/Berlin/berlin-districts.geojson` |
| City outline | Union of the districts (slivers closed, simplified to 2 m) | CC BY 3.0 DE | `App/MapQuest/Resources/Berlin/berlin-boundary.geojson` |
| Sights (119, all 12 districts) | Curated list (`Tools/capture/berlin_sights.csv`); positions from OpenStreetMap points of interest via OpenFreeMap vector tiles (`Tools/capture/locate_sights.py`), 7 open areas placed by hand | ODbL 1.0 (© OpenStreetMap contributors) | `App/MapQuest/Resources/Berlin/berlin-sights.json` |
| Sight entries (text and photo) | Wikipedia introductions (English, else German) and lead photos from Wikimedia Commons (`Tools/capture/fetch_sight_info.py`) | Texts CC BY-SA 4.0; photos per entry (author and licence in the file) | `App/MapQuest/Resources/Berlin/berlin-sight-info.json` |
| Sight history (dates, style, architects, clients, history texts) | Wikidata and the articles' infoboxes, checked by hand (`Tools/capture/berlin_sight_history.csv`); the articles' history sections (`Tools/capture/fetch_sight_history.py`); rulers and eras in `BerlinHistory` | Facts: Wikidata CC0; history texts CC BY-SA 4.0 | `App/MapQuest/Resources/Berlin/berlin-sight-history.json` |
| Demo explorer track (1 Hz, TrackCodec) | Generated (`Tools/berlin/make_demo_data.py`) | – | `App/MapQuest/Resources/Berlin/demo-track.mqtrack` |
| Simulator walk | Generated, Brandenburger Tor → Alexanderplatz | – | `App/Simulation/BerlinWalk.gpx` |

For the 2D map no geographic data has to be shipped: the base map's vector
tiles are loaded on demand and cached, and the fog is computed from the user's
own positions. Berlin data is
needed to

* **restrict recording** to Berlin (`PlayArea`, point-in-polygon per fix),
* **compute statistics** – discovered share of Berlin and of each district
  (`DiscoveryStatistics.coverage`, computed tile by tile),
* **draw the boundary** as a dashed outline,
* **demonstrate data-source switching**: the view-only *Demo explorer*
  profile is filled on first use by feeding its 2 372 raw fixes through the
  `LocationRecorder`, which stores only the fixes that reveal new area and
  builds the discovered area – three regions (central Mitte, Tempelhofer Feld,
  Bergmannstraße).

The play-area code is global: replacing the two GeoJSON files (or using
`PlayArea.world`) moves the game to another city or the whole world.

### Regenerating

```bash
pip install shapely
python3 Tools/berlin/prepare_play_area.py
python3 Tools/berlin/make_demo_data.py
```

### Sights

The capture component's sights are a curated list of 119 places in all twelve
districts – landmarks, museums, palaces, churches, viewpoints, memorials,
parks, squares and more – each with a capture radius (30–150 m).
`Tools/capture/locate_sights.py` finds each one by name among the
OpenStreetMap points of interest of the zoom-14 OpenFreeMap tiles around its
approximate position: stops, entrances and signs only if nothing else
matches, then the aliases in order, exact names before partial ones, classes
fitting the category, the nearest. Seven places without a suitable point
(Tempelhofer Feld, the zoo's Elefantentor, Hauptbahnhof, Sony Center,
Gasometer, Luftbrückendenkmal, Hufeisensiedlung) keep a position set by hand
(`@manual`). The script reports every match with its distance from the
approximate position for review.

```bash
pip install mapbox-vector-tile
```

```bash
python3 Tools/capture/locate_sights.py Tools/capture/berlin_sights.csv --cache build-sights App/MapQuest/Resources/Berlin/berlin-sights.json
```

Their entries (`berlin-sight-info.json`, all 119, 115 with a photo; logos and other drawings are skipped) are
built by `Tools/capture/fetch_sight_info.py` from Wikipedia and Wikimedia
Commons (docs/02, "Capture"); `Tools/capture/berlin_sight_articles.csv` fixes
the eleven sights whose name is no article (e.g. Reichstag, Altes Museum,
Schloss Biesdorf). Wikimedia limits requests from shared networks: the script
batches (about 40 requests), waits on "429" answers and caches every answer,
so a re-run only fetches what is new.

```bash
python3 Tools/capture/fetch_sight_info.py App/MapQuest/Resources/Berlin/berlin-sights.json App/MapQuest/Resources/Berlin/berlin-sight-info.json --cache build-sights/wiki --aliases Tools/capture/berlin_sights.csv --overrides Tools/capture/berlin_sight_articles.csv
```

Their historical facts (`berlin-sight-history.json`: all 119 dated, about 100
with architects, style and client, 81 with a history section) are built by
`Tools/capture/fetch_sight_history.py` from the same articles and their
Wikidata items (docs/02, "Capture"), with the hand-checked table
`Tools/capture/berlin_sight_history.csv` taking precedence: the year a
building was put up (Wikidata often has the founding year of the institution
in it), architects, clients, and whether the sight lay in East or West Berlin.
Every sight needs a row there; an empty cell keeps the fetched value, "-"
clears it. It shares the cache (and the patience with rate limits) of the
entries.

```bash
pip install mwparserfromhell
```

```bash
python3 Tools/capture/fetch_sight_history.py App/MapQuest/Resources/Berlin/berlin-sights.json App/MapQuest/Resources/Berlin/berlin-sight-info.json App/MapQuest/Resources/Berlin/berlin-sight-history.json --cache build-sights/wiki
```

### Simulating a walk

`App/Simulation/BerlinWalk.gpx` walks from the Brandenburger Tor along Unter
den Linden to Alexanderplatz at 1.4 m/s. The scheme does not simulate a
location by default (the app uses the real position); pick the walk, or any
other location, from Xcode's *Debug › Simulate Location* menu while the app
runs.

## 3D

| Data | Source | Licence | Where |
|---|---|---|---|
| Building footprints (LoD1) | OpenStreetMap, [Geofabrik Berlin extract](https://download.geofabrik.de/europe/germany/berlin.html) | ODbL 1.0 | bundled `berlin-buildings.sqlite.deflate` |
| Building heights | Berlin's official [LoD2 building models](https://gdi.berlin.de/data/a_lod2/atom) (Geoportal Berlin), else OSM tags/estimates | dl-de/zero-2-0 | same database |
| Buildings anywhere else | OpenStreetMap via the Overpass API, downloaded on demand | ODbL 1.0 | App cache `Application Support/MapQuest/Buildings/buildings.sqlite` |
| Terrain | ATKIS® DGM 1 m ([Geoportal Berlin](https://gdi.berlin.de/data/dgm1/atom)), averaged to a ≈ 30 m grid | dl-de/zero-2-0 | `App/MapQuest/Resources/Berlin/berlin-terrain.dem` (3.8 MB) |

**Bundled database.** The app ships the whole of Berlin as
`App/MapQuest/Resources/Berlin/berlin-buildings.sqlite.deflate` (raw DEFLATE,
≈ 30 MB, built by `Tools/berlin/build_buildings.sh`). On first launch – and after every update of the file – the
app unpacks it into `Application Support/MapQuest/Buildings/berlin.sqlite`
(≈ 51 MB) in the background. A `LayeredBuildingCache` combines it with the
download cache, so tiles across the city limits still come from Overpass
(downloads are limited to the surroundings of the bundled cities; elsewhere
the line of sight reveals the radius circle).

**LoD2 heights.** `Tools/berlin/extract_lod2.py` streams the ~925 CityGML
tiles (1 × 1 km) and writes every building and building part with its own
ground surface: `measuredHeight` (or roof top minus ground) and the ground
polygon in WGS84. `Tools/berlin/apply_lod2_heights.py` keeps the OSM
footprints and gives each one the height of the **tallest LoD2 part lying
mostly (≥ 50 %) inside it** – towers that LoD2 models as separate parts
(Rotes Rathaus, Berliner Dom, Funkturm) would otherwise be lost. Without such a
part, the part covering most of the footprint (≥ 30 %) is used. An explicit
OSM `height` that is taller wins: LoD2 stops below antennas (Fernsehturm:
229 m in LoD2, 368 m in OSM) and predates the newest towers. Such buildings
get height source `measured`.

Result (bundled database, November 2026): 539 018 buildings; heights measured
(LoD2) 79.6 %, OSM `height` tag 0.8 %, OSM levels 3.1 %, estimated 16.5 %
(before LoD2: 1.4 % tagged, 33 % levels, 66 % estimated). Landmarks: Fernsehturm
368 m, Funkturm 147 m, Berliner Dom 98 m, Rotes Rathaus 84 m, Brandenburger
Tor 26 m. 56.5 MB unpacked, 31.7 MB in the app bundle.

Without bundled data the app still works: the first time the
line-of-sight layer or the 3D map needs an area, `CachingBuildingSource`
downloads its zoom-14 tile (≈ 1.5 × 1.5 km in Berlin) from Overpass and keeps
it in the local building cache. This makes the 3D mode work worldwide.

For offline use, the complete Berlin dataset can be bundled:

1. **Extract** – `Tools/berlin/extract_buildings.py` (pyosmium) reads the
   Geofabrik PBF and writes every building way and assembled multipolygon as
   an Overpass-style JSON line.
2. **Import** – `swift run -c release mapquest-import buildings` (in
   `MapQuestKit/`) parses those lines with the app's own
   `OverpassBuildingParser` and height rules, writes `berlin-buildings.sqlite`
   in the app's `SQLiteBuildingStore` schema, and marks every zoom-14 tile that
   lies completely inside Berlin as complete (border tiles are completed from
   Overpass on demand).
3. **Ship** – copy the database to
   `App/MapQuest/Resources/Berlin/berlin-buildings.sqlite` (git-ignored) and
   regenerate the project. On first launch the app copies it into its building
   cache.

`Tools/berlin/build_buildings.sh` runs all of this including the LoD2
heights (below) and writes the compressed database for the app bundle:

```bash
Tools/berlin/build_buildings.sh
```

Step by step:

```bash
curl -fsSL -o berlin.osm.pbf https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf
```

```bash
python3 Tools/berlin/extract_buildings.py berlin.osm.pbf buildings.jsonl
```

```bash
cd MapQuestKit && swift run -c release mapquest-import buildings --output ../App/MapQuest/Resources/Berlin/berlin-buildings.sqlite --complete-inside ../App/MapQuest/Resources/Berlin/berlin-boundary.geojson ../buildings.jsonl
```

### Result (Geofabrik extract of 7 November 2026)

| | |
|---|---|
| Buildings | 539 018 (536 385 ways, 2 613 multipolygons), 0 unreadable |
| Height from `height` tag | 7 489 (1.4 %) |
| Height from `building:levels` | 175 829 (32.6 %) |
| Estimated from building type | 355 700 (66.0 %) |
| Tallest | Fernsehturm 368 m, Funkturm 147 m, The Berlinian 146 m, EDGE East Side Tower 142 m |
| Complete zoom-14 tiles | 321 |
| Database | 51 MB, shipped compressed (raw DEFLATE) |

Viewsheds computed on this data by `mapquest-import viewshed` (release build,
as in `build_buildings.sh`):

| Place | Eye height | Sight | Buildings seen | Visible | Time |
|---|---|---|---|---|---|
| Alexanderplatz (open square) | 1.7 m | 150 m | 13 | 88 % of the view disk | 37 ms |
| Unter den Linden | 1.7 m | 150 m | 19 | 107 %¹ | 30 ms |
| Kreuzberg side street | 1.7 m | 150 m | 14 | 16 % | 46 ms |
| Tempelhofer Feld | 1.7 m | 150 m | 0 | 99.7 % | 28 ms |
| Fernsehturm viewing deck | 192 m | 2 000 m | 5 419 | 5.5 km² (44 %) | 1.3 s |
| Park Inn rooftop | 114 m | 1 830 m | 4 222 | 3.5 km² (33 %) | 0.5 s |

¹ Seen buildings count with their whole footprint, which can reach beyond
the view distance (Staatsoper, Humboldt University).

**Heights.** OSM `height` tags are used where present, then
`building:levels` × 3 m (+ roof levels), otherwise a per-type estimate (see
`OSMBuildingHeights`). Berlin's official LoD2 model and building heights
(Geoportal Berlin, dl-de/zero-2-0) would be a more precise source and can be
imported into the same schema later.

**Terrain.** `Tools/berlin/prepare_terrain.py` downloads the 297 tiles of
the official 1 m terrain model (≈ 3.5 GB of XYZ text), averages them into 25 m
UTM cells and resamples them onto a 0.00027° × 0.00045° (≈ 30 m)
latitude/longitude grid: 1 266 × 1 512 cells, 23.7–120.8 m (median 40.5 m),
stored as int16 decimetres. `GridTerrain` reads it; outside the grids of all
bundled cities positions count as street level (`CompositeTerrain`). With it

* the eye height is measured against the real ground, so walking on the
  Barnim or Teltow plateau (45–60 m) is street level, not a "high point";
* the view distance uses the height above the *surrounding* terrain (mean
  of a 300 m ring), so hilltops such as Teufelsberg or the Kreuzberg see far;
* the line-of-sight sweep samples the ground along each ray, so hills hide
  what lies behind them.

The debug settings can switch the terrain off (flat 35 m) for comparison.
