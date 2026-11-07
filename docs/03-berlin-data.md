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
| Building footprints and heights (LoD1) | OpenStreetMap, [Geofabrik Berlin extract](https://download.geofabrik.de/europe/germany/berlin.html) | ODbL 1.0 | `berlin-buildings.sqlite` (CI artifact, optionally bundled) |
| Buildings anywhere else | OpenStreetMap via the Overpass API, downloaded on demand | ODbL 1.0 | App cache `Application Support/MapQuest/Buildings/buildings.sqlite` |
| Terrain | Flat, 35 m above sea level (`FlatTerrain.berlin`) | – | – |

The app works without any bundled building data: the first time the
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
