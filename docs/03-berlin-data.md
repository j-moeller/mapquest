# MapQuest – Berlin data

Berlin is the first play area. This page lists every dataset the app uses for
Berlin, where it comes from, and how to regenerate it.

## 2D

| Data | Source | Licence | File |
|---|---|---|---|
| Base map | Apple Maps via MapKit | Apple Maps terms | – (streamed by MapKit) |
| District boundaries (12 Bezirke) | Amt für Statistik Berlin-Brandenburg, merged from localities by [m-hoerz/berlin-shapes](https://github.com/m-hoerz/berlin-shapes) | CC BY 3.0 DE | `App/MapQuest/Resources/Berlin/berlin-districts.geojson` |
| City outline | Union of the districts (slivers closed, simplified to 2 m) | CC BY 3.0 DE | `App/MapQuest/Resources/Berlin/berlin-boundary.geojson` |
| Demo explorer walks | Generated (`Tools/berlin/make_demo_data.py`) | – | `App/MapQuest/Resources/Berlin/demo-walks.json` |
| Simulator walk | Generated, Brandenburger Tor → Alexanderplatz | – | `App/Simulation/BerlinWalk.gpx` |

For the 2D map no geographic data has to be shipped: Apple Maps provides the
base map, and the fog is computed from the user's own positions. Berlin data is
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

### Simulating a walk

The Xcode scheme uses `App/Simulation/BerlinWalk.gpx` as the default simulated
location, so running in the iOS Simulator walks from the Brandenburger Tor
along Unter den Linden to Alexanderplatz at 1.4 m/s. Other locations can be
picked from Xcode's *Debug › Simulate Location* menu.

## 3D

| Data | Source | Licence | Where |
|---|---|---|---|
| Building footprints (LoD1) | OpenStreetMap, [Geofabrik Berlin extract](https://download.geofabrik.de/europe/germany/berlin.html) | ODbL 1.0 | bundled `berlin-buildings.sqlite.deflate` |
| Building heights | Berlin's official [LoD2 building models](https://gdi.berlin.de/data/a_lod2/atom) (Geoportal Berlin), else OSM tags/estimates | dl-de/zero-2-0 | same database |
| Buildings anywhere else | OpenStreetMap via the Overpass API, downloaded on demand | ODbL 1.0 | App cache `Application Support/MapQuest/Buildings/buildings.sqlite` |
| Terrain | Flat, 35 m above sea level (`FlatTerrain.berlin`) | – | – |

**Bundled database.** The app ships the whole of Berlin as
`App/MapQuest/Resources/Berlin/berlin-buildings.sqlite.deflate` (raw DEFLATE,
≈ 30 MB, committed by the *Berlin building data* workflow when run manually
with *commit*). On first launch – and after every update of the file – the
app unpacks it into `Application Support/MapQuest/Buildings/berlin.sqlite`
(≈ 51 MB) in the background. A `LayeredBuildingCache` combines it with the
download cache, so areas outside Berlin still come from Overpass.

**LoD2 heights.** `Tools/berlin/extract_lod2.py` streams the ~925 CityGML
tiles (1 × 1 km) and writes every building and building part with its own
ground surface: `measuredHeight` (or roof top minus ground) and the ground
polygon in WGS84. `Tools/berlin/apply_lod2_heights.py` keeps the OSM
footprints but gives each one the height of the LoD2 part that overlaps it
most (at least 30 % of the footprint); such buildings get height source
`measured`.

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

The workflow `.github/workflows/berlin-buildings.yml` runs all of this on
GitHub Actions and publishes the database as the `berlin-buildings` artifact
(run it from the Actions tab). Locally:

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
| Database | 51 MB (31 MB zipped) – too large for the git repository, hence a CI artifact |

Viewsheds computed by the workflow on this data (release build on a GitHub
runner):

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

**Terrain.** Berlin's relief is modest (Spree valley ≈ 34 m, Barnim and
Teltow plateaus 45–60 m, Teufelsberg 120 m). The viewshed treats the ground
as flat at 35 m and only counts heights more than 8 m (plus the vertical
accuracy) above that as an elevated viewpoint. Plugging a DEM (e.g. Berlin's
DGM1 open data) into `TerrainModel` removes this limitation.
