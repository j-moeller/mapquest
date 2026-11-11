# MapQuest – Architecture

The rationale for the choices below is in the
[literature review](01-literature-review.md).

## Code layout

| Path | Contents | Platforms |
|---|---|---|
| `MapQuestKit/` | Swift package with all platform-independent logic | iOS, macOS, Linux |
| `MapQuestKit/Sources/MapQuestCore` | Geo primitives, data model, store protocols, discovery | |
| `MapQuestKit/Sources/MapQuestSQLite` | SQLite implementation of the stores | |
| `MapQuestKit/Sources/MapQuestTestSupport` | Contract tests every store must pass | |

The package builds and tests on Linux (`swift test` in `MapQuestKit/`), so
the core can be verified without Xcode.

## Data model

### Coordinates

* `GeoCoordinate` – WGS84 latitude/longitude in degrees.
* `WorldPoint` – integer Web Mercator coordinates in a `2^32 × 2^32` world
  (origin north-west, y grows south). One unit ≈ 5.7 mm in Berlin.
  MapKit's `MKMapPoint` is the same projection with a `2^28` world, so
  `MKMapPoint = WorldPoint / 16`.
* `TileKey` / `TileRange` – slippy-map tiles. The storage grid is zoom 16
  (`DiscoveryGrid.zoom`, 372 m tiles in Berlin).

### Location data (source of truth)

`LocationSample` is a 3D position fix:

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | Client-generated, so samples merge into any store |
| `latitude`, `longitude` | Double | WGS84 degrees |
| `altitude` | Double | Metres above mean sea level |
| `horizontalAccuracy` | Double | 1σ metres, negative = invalid |
| `verticalAccuracy` | Double | Metres, negative = altitude invalid |
| `timestamp` | Date | When the fix was taken (timeline) |
| `tile` *(derived)* | TileKey | Zoom-16 tile: the spatial index key |

These *key samples* are the fixes that changed the map; the discovered area is
derived from them. Every fix (about one per second) is also kept in the
**track** (below).

### Track (continuous location data)

`TrackPoint` is a quantized fix – time in 0.1 s, latitude/longitude in 10⁻⁶°
(≈ 0.11 m), altitude and accuracies in decimetres. `TrackCodec` stores runs of
fixes as zig-zag varint deltas (≈ 6 bytes per fix at 1 Hz, lossless after
quantization; docs/01-literature-review.md §2.6). A `TrackSegment` is one such
run (≤ 600 fixes, no gap over 2 minutes) with its time span and bounding box;
segments are the unit of storage and query (`TrackStore`). The `TrackWriter`
buffers the open segment and rewrites it every 30 fixes or 30 s, so at most
that much is lost if the app is killed; it is flushed when the app goes to
the background. Track points become `LocationSample`s with IDs derived from
their time, so period computations can refresh like the main layers.

### Discovered area (cache)

* `DiscoveryLayerID` – one layer per discovery model (`circle-50m`,
  `viewshed-v1`, …).
* `DiscoveredPiece` – a connected polygon with holes (`WorldPolygon`) inside
  one storage tile, clipped to the tile grown by a 2 m margin. Carries its
  `regionID`, the area inside the exact tile, and first/last discovery time.
* `DiscoveredRegion` – a connected component, aggregated from pieces.
* `DiscoveredAreaChangeSet` – an atomic modification of one layer: region
  merges (relabelling), piece removals, piece upserts – applied in that order.

### Geometry encoding

Polygons are stored as rings of zig-zag encoded coordinate deltas in LEB128
varints (`PolygonCodec`, version 1), relative to the tile origin:

```
u8 version=1 | varint ringCount | per ring: varint pointCount, per point: zz(dx), zz(dy)
```

The first ring is the exterior, the others are holes. The first point of a
ring is relative to the last point of the previous ring.

## Store abstraction

```swift
protocol LocationStore        // addSamples, samples(matching:), sampleCount, removeAllSamples
protocol DiscoveredAreaStore  // pieces(layer:tiles:), apply(changeSet), removeAllPieces, layers
protocol MapQuestDataStore: LocationStore, DiscoveredAreaStore { var descriptor { get } }
```

The app only talks to `MapQuestDataStore`. Swapping it – a different local
database file, an in-memory store, or a remote implementation – switches the
complete data shown by the app, because location data and discovered area
always travel together. Implementations:

| Store | Use |
|---|---|
| `InMemoryDataStore` | Tests, previews, staging during cache rebuilds |
| `SQLiteDataStore` | The local database: one SQLite file per data source (user profile) |

### SQLite schema (version 3, `PRAGMA user_version`)

```sql
CREATE TABLE location_samples (
    id TEXT PRIMARY KEY,            -- UUID
    latitude REAL, longitude REAL,  -- WGS84 degrees
    altitude REAL,                  -- metres above mean sea level
    horizontal_accuracy REAL, vertical_accuracy REAL,
    timestamp REAL,                 -- Unix seconds (UTC)
    tile_x INTEGER, tile_y INTEGER  -- zoom-16 tile = spatial index key
);
CREATE INDEX location_samples_tile ON location_samples (tile_x, tile_y);
CREATE INDEX location_samples_time ON location_samples (timestamp);

CREATE TABLE discovered_pieces (
    id TEXT PRIMARY KEY, layer TEXT, region_id TEXT,
    tile_zoom INTEGER, tile_x INTEGER, tile_y INTEGER,
    geometry BLOB,                  -- PolygonCodec v1, relative to the tile origin
    area_m2 REAL,                   -- area inside the exact tile
    first_discovered REAL, last_updated REAL
);
CREATE INDEX discovered_pieces_tile ON discovered_pieces (layer, tile_x, tile_y);
CREATE INDEX discovered_pieces_region ON discovered_pieces (layer, region_id);

CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT);

-- version 2: data watermarks (docs/05-cache-invalidation.md)
CREATE TABLE layer_data_versions (
    layer TEXT, zoom INTEGER, x INTEGER, y INTEGER, version TEXT,
    PRIMARY KEY (layer, zoom, x, y)
) WITHOUT ROWID;

-- version 3: the continuous track
CREATE TABLE track_segments (
    id TEXT PRIMARY KEY, start_time REAL, end_time REAL,
    min_x INTEGER, min_y INTEGER, max_x INTEGER, max_y INTEGER,  -- world bounding box
    point_count INTEGER, data BLOB                               -- TrackCodec v1
);
CREATE INDEX track_segments_time ON track_segments (start_time, end_time);
```

The store runs every call on a private serial dispatch queue and uses WAL
journaling for file databases. Nothing in the schema is SQLite-specific: the
same tables map directly to PostgreSQL, and the tile columns work as keys in
document stores.

Every store implementation is verified against the same contract tests
(`DataStoreContract` in the test target).

## Discovery (the discovered-area component)

### Discovery models and layers

A `DiscoveryModel` turns one `LocationSample` into the area it reveals.
Each model writes its own layer:

| Model | Layer | Revealed area |
|---|---|---|
| `CircleDiscoveryModel` (2D) | `circle-50m` | 64-gon of radius *r* around the sample |
| `ViewshedDiscoveryModel` (3D) | `viewshed-v1` | Visible ground + seen buildings (see 3D section) |

### `DiscoveryEngine` – one per layer

* **`evaluate(sample)`** – computes the revealed area and how much of it is
  new: for every storage tile the revealed area touches, clip it to the exact
  tile and subtract that tile's pieces. Read-only.
* **`commit(evaluation)` / `merge(polygons, at:)`** – merges revealed area:
  1. Split the revealed area into connected components (Clipper2 union).
  2. For each component *C*: grow it by the adjacency tolerance ε (1 m) and
     collect every cached piece it intersects (tiles within margin + ε).
  3. The touched regions are merged; the **oldest** region (by first
     discovery) keeps its ID, all others are relabelled to it. No touched
     region → a new region (UUID).
  4. For each tile, clip *C* to the tile grown by the 2 m margin, union it
     with the touched pieces of that tile, simplify (5 cm), and replace those
     pieces by the resulting connected polygons (new pieces, new IDs).
  5. Everything is written as one `DiscoveredAreaChangeSet`.
* **`rebuild(from: samples)`** – replays samples chronologically into an empty
  in-memory layer and replaces the stored layer in one step. Because regions
  are connected components, the result does not depend on processing order.
* **`snapshot()`** – an immutable, tile-indexed copy for rendering and stats.
* **`isDiscovered(coordinate)` / `region(at:)`** – point queries.

The engine keeps a tile cache; `loadAll()` loads a whole layer (the app does
this at start), otherwise tiles are loaded lazily on first use.

### `LocationRecorder` – the location-tracking core

Receives every position fix and:

1. writes every valid fix to the track (the app does this directly, so the
   track keeps recording while a layer is rebuilt);
2. rejects fixes worse than 50 m (1σ) (and fixes outside a play area, if one
   is set – the app records everywhere);
3. lets the `CoverageSampler` choose the fixes worth evaluating: about one per
   10 m of movement, corners and climbs, nothing for jitter while standing
   still (docs/01-literature-review.md §2.6; a viewshed from a tower takes
   about a second);
4. evaluates the sampled fix with every engine;
5. stores the fix as a key sample only if, for at least one layer, ≥ 10 % of
   the revealed area or ≥ 2 000 m² is new (`RecordingPolicy`);
6. commits every stored fix to **every** layer, so each layer always equals a
   rebuild from the stored samples.

With a 50 m radius this stores about one fix per 10 m of *new* path and none
while moving through known territory.

### Time-based views and statistics

`Period` is a calendar day, week, month or year (the user's calendar).
`PeriodDiscovery` computes the area revealed during a period with any
discovery model: a day's track is reduced by the `CoverageSampler` (revisits
merged) and rebuilt in a scratch engine. Completed days are cached as layers
`<layer>@day:<date>:s<spacing>` in the data store, with data watermarks, so new
building data recomputes them; the current day is recomputed when its track
grew. Weeks, months and years are per-tile unions of their days.
`TrackStatistics` gives distance (along the sampled path, so jitter does not
add up), recorded time and active days, also per day.

`HeatmapGrid` bins `WeightedPoint`s (time until the next fix, ≤ 5 s) into a
grid, blurs it three times with a box filter (≈ Gaussian) and colours it on a
logarithmic scale up to the hottest cell (faint tails below 3 % stay
transparent).

### Cities

The app bundles data per city (`Cities`): `<id>-boundary.geojson`,
`<id>-districts.geojson`, `<id>-terrain.dem` and
`<id>-buildings.sqlite.deflate`, each optional. Positions are recorded and the
fog of war lifts **everywhere**; the cities only add data for the
line-of-sight layer: the terrain models form a `CompositeTerrain` (where none
has data, fixes count as street level), the building databases a
`CompositeBuildingCache`, and buildings are downloaded (OpenStreetMap) only for
data tiles within 2 km of a city (`CachingBuildingSource.setDownloadRegion`;
a debug setting allows downloads everywhere). Elsewhere the line of sight
reveals the radius circle (the default map, docs/05). Berlin: docs/03-berlin-data.md; Braunschweig:
docs/06-braunschweig-data.md; Peine (official outline and LoD2 buildings, no
districts): docs/07-peine-data.md.

## Capture (the capture component)

A separate component on top of the discovered area: **sights** – 119 places
all over Berlin (every district), from a curated list – are *captured* once the
fog of war around them is lifted. It only reads the discovered area and keeps
its own data; nothing else depends on it.

* **Sights** (`MapQuestCore/Capture/Sight.swift`): ID, name, category
  (landmark, museum, palace, church, viewpoint, memorial, park, square,
  culture, monument, zoo, bridge, stadium), position and extent
  (30–150 m; larger for open areas). Bundled per city as
  `<city>-sights.json` (Berlin: docs/03-berlin-data.md); `SightCatalog`
  merges them.
* **Capture rule** (`SightCapture`): a sight is captured when you have been
  there – when the **radius layer** (the circles around your positions, all
  time) covers its position. Large open areas count from inside: the circles
  must reach within their extent minus 50 m (`Sight.captureTolerance`; e.g.
  Tempelhofer Feld, 150 m → 100 m). The line of sight does not count: seeing
  a sight from afar is not having been there. The capture date is the first
  discovery of the covering area. Captures are kept once made (a rebuild with
  other parameters does not take them away); deleting a data source's
  discovered area deletes its captures. A change of the rule bumps
  `CaptureLog.currentVersion`: logs of an older rule are discarded once and
  the sights checked again (version 2: radius layer only; version 1 counted
  any layer within the extent). *Debug › Reset captured sights* does the same
  on demand.
* **Log** (`CaptureLog`, `FileCaptureStore`): one JSON file per data source
  in `Application Support/MapQuest/Captures`, separate from the data stores;
  per capture the dates and whether it was celebrated.
* **App** (`App/MapQuest/Capture`): `CaptureModel` re-checks the
  uncaptured sights (off the main thread) whenever the selected data source's
  discovered area changes. New captures of a recording data source are
  celebrated by `CaptureCelebrationView` – a golden medallion with the
  sight's icon bursts in over the dimmed screen with turning rays and flying
  sparks (haptic success; reduced motion: a fade); it ends after 4.5 s, a tap
  anywhere ends it at once. One capture at a time; more than three waiting
  (e.g. the first check of earlier discoveries) are celebrated together.
  View-only data sources record captures without celebrating.
* **Views**: the trophy button in the status panel (number of captures)
  opens one list of all sights, nearest first – captured ones in orange
  (with their capture date), the others in grey; tapping one shows it on the
  2D map. On the 2D map captured
  sights are golden badges with their category icon (annotations, above the
  fog; a callout gives name and date); *Debug › Show all sights* marks the
  others as grey "?". In 3D every sight in the scene floats as a turning gem
  on a beam – gold with its name once captured, grey "?" otherwise – and the
  building of a captured sight is drawn in gold.

## 3D discovery (line of sight)

### Buildings

`Building` is an LoD1 block: footprint (`WorldPolygon`, courtyards as holes),
`height` and `minHeight` above ground, and where the height came from.
`BuildingSource` provides buildings for a world rectangle:

| Type | Role |
|---|---|
| `InMemoryBuildingSource` | Fixed sets (tests) |
| `CachingBuildingSource` | Serves zoom-14 tiles (≈ 1.5 km) from a `BuildingCache`, downloads missing tiles on demand, keeps recent tiles in memory |
| `SQLiteBuildingStore` | The persistent `BuildingCache` (shared by all data sources – it is map data, not user data); can be seeded with a bundled `berlin-buildings.sqlite` |
| `OverpassClient` | Downloads OSM buildings (`way`/`relation` `building=*`, towers with `height`) for a box |

`OSMBuildingHeights` derives heights from OSM tags: `height` →
`building:levels` × 3 m (+ roof levels/height) → an estimate per building type
(garage 3 m, house 8 m, apartments 17 m, …, default 12 m). `min_height` /
`building:min_level` mark passages and bridges; `building=roof` canopies do not
block the view.

### `ViewshedDiscoveryModel`

1. **Eye height**: the fix's altitude minus the terrain elevation, minus the
   vertical accuracy and an 8 m threshold, so GNSS noise and moderate relief
   count as street level (1.7 m). Unreliable altitudes (vertical accuracy
   missing or > 15 m) also mean street level. `FlatTerrain.berlin` (35 m) is
   the default terrain; a DEM can be plugged in via `TerrainModel`.
2. **View distance**: 150 m at street level, +15 m per metre of eye height,
   at most 2 km.
3. **`Viewshed.compute`**: 720 rays; buildings are indexed in a 25 m grid
   and found per ray by voxel traversal; each building crossing yields an
   entry/exit interval; the slope sweep decides what is visible (see the
   literature review, §4.4). The building the user stands in is seen but not
   an obstacle.
4. Visible ground intervals become thin wedges, which are united with the
   footprints of all seen buildings (Clipper2) and simplified (0.5 m).

The result feeds a second `DiscoveryEngine` (layer `viewshed-v1`), so the 3D
layer gets exactly the same tiling, region merging, persistence and rebuild
as the 2D layer. In release builds one viewshed takes ≈ 10 ms.

### Failure handling

If building data is unavailable (offline, never downloaded), the 3D model
throws. The `LocationRecorder` still stores the fix and updates the 2D layer,
marks the 3D layer as *stale*, and the app offers a rebuild once online.

## App (iOS)

| File | Role |
|---|---|
| `App/MapQuest/Location/LocationTracker.swift` | `CLLocationManager` wrapper: permission, continuous updates (also in the background), significant-change relaunch |
| `App/MapQuest/AppModel.swift` | Writes every fix to the track and streams fixes through the `LocationRecorder`, owns the selected data source, publishes snapshots and statistics, refreshes areas when building data changes |
| `App/MapQuest/ViewOptions.swift`, `Views/ViewBar.swift` | Viewing options: fog of war or heatmap; all time or a day/week/month/year (computed in the background, live while the period includes now) |
| `App/MapQuest/Cities.swift` | Bundled cities (outline, districts, terrain, buildings) |
| `App/MapQuest/DataSourceCatalog.swift` | Profiles (own data, other users, demo); one SQLite file each; only the own profile records |
| `App/MapQuest/Map2D/BaseMapTiles.swift` | Map data (OpenFreeMap vector tiles: download, disk cache) and the label-free map tiles drawn from it |
| `MapQuestKit/Sources/MapQuestCore/BaseMap/*` | Vector tile decoder (MVT), map style (what is drawn, order, widths, palettes), TileJSON |
| `App/MapQuest/Map2D/FogMapRenderer.swift` | Draws base map and fog of war together inside MapKit's rendering |
| `App/MapQuest/Map2D/MapLabels.swift` | City and district names above the fog |
| `App/MapQuest/Map2D/HeatmapLayerView.swift` | Heatmap raster and dimming over the map |
| `App/MapQuest/Map2D/FogMapView.swift` | `MKMapView` wrapper: overlays, labels, outlines, user tracking |
| `App/MapQuest/Capture/*` | Capture component: model, sight list, capture animation, map badges, 3D markers |
| `MapQuestKit/Sources/MapQuestCore/Capture/*` | Sights, capture rule, capture log and its file store |
| `App/MapQuest/Map3D/*` | SceneKit scene: extruded buildings, fogged ground, user marker |
| `App/MapQuest/Debug/*` | Debug settings (parameters, test positions, evaluation overlay) |
| `App/MapQuest/BundledBuildings.swift` | Unpacks the bundled building databases (one per city) |
| `App/MapQuest/Keychain.swift`, `Views/AddRemoteSourceView.swift` | Remote data sources (token in the Keychain) |
| `App/MapQuestUITests/` | Smoke test on an iPhone 13 mini simulator (run from Xcode) |
| `App/MapQuest/Views/*` | Main screen (2D/3D switch), statistics panel, settings, districts |

### 3D map (SceneKit)

`Map3DScreen` shows a 1.4 km × 1.4 km square around the user (or
Alexanderplatz):

* **Buildings** are loaded from the `CachingBuildingSource` and extruded by
  `LoD1MeshBuilder` (MapQuestCore, unit-tested) into one mesh: walls with
  outward normals, roofs triangulated with Clipper2 (courtyards stay open),
  undersides for raised buildings. Every building is coloured by the
  **line-of-sight layer**: warm sand if its interior point is discovered,
  dark slate otherwise.
* **Ground**: the 2D map's label-free base map stitched for exactly the
  scene's Web Mercator rectangle (an Apple Maps snapshot without points of
  interest if the tiles are unavailable), with the same fog as the 2D map, on
  an unlit plane.
* **User marker** at eye height; the HUD shows the estimated eye height, the
  resulting view distance and the number of buildings.
* Orbit/pan/zoom via SceneKit's camera controller; recolouring runs off the
  main thread whenever the layer changes.

SceneKit was chosen for its built-in camera control; the mesh code is
renderer-independent, so a later move to RealityKit only replaces
`SceneKitMesh.swift` and `Map3DView.swift`.

### Debug settings

The debug panel tunes parameters on the device. It is a sheet over the map
(slider button in the map's top bar, or *Settings › Developer › Debug
settings*) with three heights; at the small and medium heights the map above
it stays visible and interactive (`presentationBackgroundInteraction`), so
changes can be watched – and the map panned, zoomed or long-pressed for test
positions – while tuning (`Debug/DebugPanel.swift`).

| Group | Parameters | Effect |
|---|---|---|
| Map | fog opacity (black, up to 100 %, default 80 %), blur under the fog (default 25 %), soft fog edges (metres), base map (streets, light, dark) | immediate (2D map and 3D ground) |
| Radius layer | radius | new layer `circle-<r>m`, rebuilt from the stored positions |
| Line-of-sight layer | rays, sight at street level, extra sight per metre, maximum sight, street-level threshold, terrain on/off | new layer `viewshed-v3-<terrain>-<hash>`, rebuilt |
| Recording | new-area threshold, movement before re-evaluating | immediate, for new positions |
| Testing | long-press the 2D map to place a position, eye height of test positions, "place here", evaluation details overlay | immediate |

Because discovery parameters are part of the layer ID, the cache can never
mix results of different parameters. On every load the app rebuilds layers
that do not exist yet (new parameters or a new app version). Old layers stay
cached until *Delete unused cached layers*. The *Sandbox (testing)* data
source records like the user's own one, so experiments do not touch real
discoveries.

### Base map and fog rendering (2D)

**No labels.** Apple Maps cannot hide its labels (street, place and POI names;
only its satellite imagery has none), and MapKit does not let an app process
its map image. The 2D map therefore draws its own base map on the device from
OpenStreetMap vector data, leaving out every label and icon:

* **Data**: OpenFreeMap's vector tiles (OpenMapTiles schema, zoom 0–14; free,
  no key, no sign-up; credit "OpenFreeMap © OpenMapTiles · Data © OpenStreetMap
  contributors" on the map). The TileJSON (tile URLs change with each data
  release) is fetched once per launch and kept for offline use. Requests carry
  an app User-Agent; only tiles the map needs are loaded, no bulk downloads.
  (OpenStreetMap's own tile server only serves its labelled standard style,
  so it is not used; its tile usage policy therefore does not apply.)
* **Cache**: every downloaded tile is stored zlib-compressed in
  `Application Support/MapQuest/MapData` (excluded from backups, limited to
  500 MB, oldest first out) and reused offline and for every deeper zoom;
  tiles older than 90 days are refreshed in the background when used.
  Decoded tiles and drawn tiles are kept in memory. *Settings › Map data*
  shows the size and deletes it.
* **Drawing** (`MapRenderPlan`, MapQuestCore, unit-tested with a real tile):
  only the layers `landuse`, `landcover`, `water`, `waterway`, `aeroway`,
  `transportation` and `building` are decoded (`VectorTile`, a small protocol
  buffer reader); names, house numbers and POIs are never read. Fills
  (land use, land cover, water, buildings from zoom 14) and strokes
  (waterways, runways, roads with casings, tunnels below and bridges above,
  dashed paths and tracks, railways) are ordered like a regular map; widths
  follow per-class zoom stops. Tiles are drawn at 512 pixels for 256 points;
  beyond zoom 14 the zoom-14 data is drawn enlarged, so lines stay sharp up
  to zoom 21. Three palettes: streets, light, dark.

**Start-up.** The map opens where it was left (saved after every move), whose
map data is on disk and appears at once; without a saved view, around the last
position iOS knows. It does not wait for the first GPS fix and does not
animate to it (an animated zoom draws every zoom level in between, often
without cached data): if the user is out of sight at the first fix, the map is
centred on them at the same zoom. While a tile's own data is loading, a
coarser tile drawn from data already on disk is shown enlarged.

Apple's map is switched off by a `GroundTileOverlay`
(`canReplaceMapContent`) that only shows a dark ground where nothing is drawn
yet. The only names on the map are the bundled cities and their districts
(`MapLabels.swift`): annotation views, which MapKit always draws above
overlays, so they stay readable on the fog; label points are computed once,
off the main thread (`WorldPolygon.labelPoint`, an approximate pole of
inaccessibility). City names appear from afar, district names closer in;
overlapping district names give way to each other (`displayPriority`).

**The fog is part of the map.** A view above the map (used before) is moved
by the app in step with the map and could be seen lagging or "gliding" while
the map decelerates. Now one world-covering overlay (`FogMapOverlay`) is drawn
by `FogMapRenderer`, an `MKOverlayRenderer`, inside MapKit's own rendering:
for every piece of the map MapKit asks for (any thread, any zoom), it

1. composes the base map tiles of the piece plus a margin into a bitmap
   (a missing tile is requested and, meanwhile, a cached coarser tile is
   enlarged; the piece is redrawn when the tile arrives);
2. rasterizes the discovered pieces of that area into a mask (each piece
   filled on its own, so overlapping neighbours simply add up; pieces below
   half a pixel and vertices closer than half a pixel are skipped);
3. turns it into the fog mask: 1 outside discovered areas, fading to 0 over
   the soft-edge width inside them (three box blurs, σ = width / 2, then
   1 − clamp(2B − 1) by table lookup – vImage);
4. draws the sharp map, and where the mask is set, the map blurred (three
   box blurs, σ = 25 % × 16 points by default) under translucent black (80 %
   by default) – Core Graphics, clipped by the mask.

Map content and its fog are the same pixels, so the fog can neither lag
behind nor glide, and no map ever appears unfogged (undrawn areas show the
dark ground). When the discovered area changes, only the map rectangles of
the changed storage tiles (plus margins) are redrawn
(`setNeedsDisplay(_:)`); style or base map changes redraw everything. City
outlines are `MKPolyline` overlays; MapKit's own location dot lies above all
overlays.

### Fog in 3D

The 3D ground texture applies the same style with Core Image: the map is
blurred where the fog lies and the fog mask is softened with a Gaussian blur.

### Heatmap rendering (2D)

In heatmap mode the fog renderer draws the plain base map, and
`HeatmapLayerView`, a view above the map, dims it and shows a raster of the
time spent: for an area three screens wide around the view, `HeatmapGrid` bins the
period's weighted fixes into 2.5-point cells, blurs them (σ ≈ 6 points) and
colours them – off the main thread; the image is placed with an affine
transform from three converted corners on every map change, and rebuilt
when the view leaves the covered area or the zoom changes by 1.5×.
