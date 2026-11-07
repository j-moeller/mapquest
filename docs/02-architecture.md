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

### SQLite schema (version 1, `PRAGMA user_version`)

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

1. rejects invalid fixes, fixes worse than 50 m (1σ) and fixes outside the
   play area;
2. evaluates the fix with every engine;
3. stores the fix only if, for at least one layer, ≥ 10 % of the revealed area
   or ≥ 2 000 m² is new (`RecordingPolicy`);
4. commits every stored fix to **every** layer, so each layer always equals a
   rebuild from the stored samples.

With a 50 m radius this stores about one fix per 8 m of *new* path and none
while moving through known territory.

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
| `App/MapQuest/AppModel.swift` | Streams fixes sequentially through the `LocationRecorder`, owns the selected data source, publishes snapshots and statistics |
| `App/MapQuest/DataSourceCatalog.swift` | Profiles (own data, other users, demo); one SQLite file each; only the own profile records |
| `App/MapQuest/Map2D/FogOverlay.swift` | World-covering `MKOverlay` and its renderer |
| `App/MapQuest/Map2D/FogMapView.swift` | `MKMapView` wrapper with fog, play-area outline and user tracking |
| `App/MapQuest/Map3D/*` | SceneKit scene: extruded buildings, fogged ground, user marker |
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
* **Ground**: an `MKMapSnapshotter` image of exactly the scene's Web Mercator
  rectangle, with the same fog cut-outs as the 2D map, on an unlit plane.
* **User marker** at eye height; the HUD shows the estimated eye height, the
  resulting view distance and the number of buildings.
* Orbit/pan/zoom via SceneKit's camera controller; recolouring runs off the
  main thread whenever the layer changes.

SceneKit was chosen for its built-in camera control; the mesh code is
renderer-independent, so a later move to RealityKit only replaces
`SceneKitMesh.swift` and `Map3DView.swift`.

### Fog rendering (2D)

`FogOverlayRenderer.draw(_:zoomScale:in:)` is called by MapKit for each map
tile, on background threads:

1. Fill the tile with translucent dark blue (58 % opacity – unexplored areas
   stay readable, but clearly darker).
2. Query the snapshot for pieces intersecting the tile (`MKMapPoint × 16 =
   world units`).
3. With blend mode `.clear`, fill every piece (even-odd per piece, so holes
   stay fogged). Vertices closer than half a screen point are skipped, which
   keeps zoomed-out rendering cheap.

When the recorder merges new area, only the changed storage tiles are
invalidated (`setNeedsDisplay(_ mapRect:)`). The fog is drawn above labels so
unexplored street names are darkened too.
