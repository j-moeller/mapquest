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
   track keeps recording while a layer is rebuilt; coarse fixes worse than
   100 m – Wi-Fi and cell positions while the tracker saves power – stay out);
2. rejects fixes worse than 50 m (1σ) (and fixes outside a play area, if one
   is set – the app records everywhere);
3. lets the `CoverageSampler` choose the fixes worth evaluating: about one per
   10 m of movement, corners and climbs, nothing for jitter while standing
   still (docs/01-literature-review.md §2.6; a viewshed from a tower takes
   about a second);
4. evaluates the sampled fix with every engine;
5. stores the fix as a key sample only if, for at least one layer, ≥ 10 % of
   the revealed area or ≥ 2 000 m² is new, or it fills a **gap**
   (`RecordingPolicy`, below);
6. commits every stored fix to **every** layer, so each layer always equals a
   rebuild from the stored samples.

With a 50 m radius this stores about one fix per 10 m of *new* path and none
while moving through known territory.

**Gaps.** Overlapping areas can enclose fog: three circles around a spot,
sight lines that just miss a corner. Such a gap is often only tens of square
metres – about 1 % of a 50 m disk – so a fix standing in it never reached the
thresholds above and the gap stayed a black spot however often you walked
through it. `DiscoveryEngine.gapFill` finds the gaps around a fix's revealed
area (holes of the discovered area within 150 m of it, across tile borders:
the pieces of neighbouring tiles are clipped and merged first) and how much of
them the fix covers; the fix is stored if it **closes** a gap (≥ 1 m²; what is
left is under 1 % or 1 m²) or fills ≥ 25 m² of gaps. Slivers of bigger gaps are
left to the usual thresholds, and the check only runs when a fix reveals
something new but too little. Gaps that versions before this rule left behind
are filled once from the track (`LocationRecorder.fillGaps`, also *Menu ›
Discovered area › Fill gaps from your track*): the track still has the
positions that walked through them, and those within the circle radius of a
gap are replayed in order through the sampler and the same rule.

### Energy

Recording runs all day, also in the background, so the app keeps its own cost
per fix low and switches GPS off when it is not needed:

* **GPS only while moving or open.** `LocationTracker` asks for full accuracy
  (`kCLLocationAccuracyBest`, every fix) while the phone moves or the app is
  open. Once the phone has stayed within 25 m of one place for three minutes
  with the app in the background (`StillnessDetector`, MapQuestCore, tested),
  it switches to `kCLLocationAccuracyHundredMeters` with a 40 m distance filter:
  no GPS, Wi-Fi and cell positions that arrive only after moving. A fix away
  from that place – beyond what both fixes' accuracies allow (each counted up
  to 65 m, so indoor and Wi-Fi jitter does not count, but a far-off cell
  position does) – switches GPS back on. Walking and cycling, and everything
  while the app is open, are recorded exactly as before (GPS, about one fix a
  second); the cost is the first stretch after setting off from a place where
  the phone lay still in the background: about 50–100 m with Wi-Fi around,
  usually known territory.
* **No GPS for data sources that record nothing** (another user's data, the
  demo).
* **Views are not redrawn per fix.** The tracker publishes `lastLocation` for
  views only after 5 m or 15 s, never in the background (`currentLocation` is
  always the latest fix, for decisions such as opening the camera). The app
  model publishes the status text and the stale layers only when they change,
  and the track's size at most every 10 s; the statistics page reads the
  current count every second while it is open (`liveTrackSummary`).
* **The background is quiet.** Changes of the discovered area are kept and
  published (merged) when the app comes back, so the map, the capture checks
  and the 3D scene do no work while nobody looks; the heatmap and time-span
  views stop their 30 s refresh in the background, and in the foreground
  refresh only when new fixes came in.

### Time-based views and statistics

`Period` is a calendar day, week, month or year (the user's calendar).
`PeriodDiscovery` computes the area revealed during a period with any
discovery model: a day's track is reduced by the `CoverageSampler` (revisits
merged) and rebuilt in a scratch engine. Completed days are cached as layers
`<layer>@day:<date>:s<spacing>` in the data store, with data watermarks, so new
building data recomputes them; the current day is recomputed when its track
grew. Weeks, months and years are per-tile unions of their days.
`TrackStatistics` gives distance (along the sampled path, so jitter does not
add up), recorded time and active days, also per day, and the distance
**walked**: a line through the fixes where they are close together in time (at
most 10 s apart) and space (between 0.5 and 3 m/s – walking and slow running,
not standing, bikes, cars or trains), each point the mean of the last five fixes
(GPS jitter evens out), thinned to points at least 5 m – or the fix's accuracy –
apart; fixes worse than 30 m draw nothing (`TrackStatistics.walkedMeters`,
tested with walks, standing still, rides, gaps and GPS jumps). The statistics
page shows it for today, this week and all time (from the whole track, every
30 s while open) and for the period shown.

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

A separate component on top of the discovered area: **sights** – 184 places
all over Berlin (every district), from a curated list – are *discovered* once
the fog of war around them is lifted (their entries unlock) and *captured* once
you photograph them there; **stations** – the 343 U-Bahn and S-Bahn stations –
are *collected* just by going there. It only reads the discovered area and
keeps its own data and photos; nothing else depends on it.

* **Sights** (`MapQuestCore/Capture/Sight.swift`): ID, name, category
  (landmark, museum, palace, church, viewpoint, memorial, park, square,
  culture, monument, zoo, bridge, stadium (and arena), fountain, market,
  government, cemetery, club),
  position, extent (30–150 m; larger for open areas) and district. Bundled per city as
  `<city>-sights.json` (Berlin: docs/03-berlin-data.md); `SightCatalog`
  merges them.
* **Three states of a sight**: **nearby** – you came within about 300 m
  (`SightCapture.nearbyDistance`: the radius layer ends within 300 m minus the
  circle radius of it, `updateNearby`, kept in `CaptureLog.nearby` with when):
  a violet "?" on the 2D map and in 3D, in the list and the locked entry; the
  callout names only the kind of place ("Undiscovered church"). Then
  **discovered** (below: its entry opens) and **captured** (photographed).
* **Visiting rule** (`PlaceCapture`, `SightCapture`, `StationCapture`): a sight is
  discovered (a station collected) when you have been there – when the
  **radius layer** (the circles around your positions, all time) covers its
  position. Large open areas count from inside: the circles must reach within
  their extent minus 50 m (`Sight.captureTolerance`; e.g. Tempelhofer Feld,
  150 m → 100 m). The line of sight does not discover: seeing a sight from afar
  is not having been there (for a while it did; `SightCapture.forgetUnreached`
  undid those discoveries once per data source, except of sights already
  photographed). It does open the camera for a discovered sight (below). The
  capture date is the first discovery of the covering area. Captures are kept
  once made (a rebuild with other parameters does not take them away);
  deleting a data source's discovered area deletes its captures. A stricter
  rule would bump `CaptureLog.currentVersion` (logs of an older rule are
  discarded – photos included – and the sights checked again). *Debug › Reset
  captured sights* starts afresh on demand.
* **Places of remembrance** (`Sight.isPlaceOfRemembrance`: the categories
  memorial and cemetery – memorials, memorial sites such as the Topographie des
  Terrors, the Stasimuseum or the Museum Karlshorst, and cemeteries; 18 in
  Berlin) are not part of the game. They are not captured (no photo, no
  "Take a photo"), are in no achievement and no count, and are never
  celebrated: a visit brings a quiet note at the bottom ("Place of
  remembrance", its name, a sentence from its entry, *Read about this place*,
  *Close*; no animation, sound or vibration). Their entries are open to
  everyone, visited or not, in stone grey, with a note that the place is not
  part of the game and – once you were there – when. On the 2D map they are
  always shown, as small stone-grey markers without reveal animation; in 3D as
  a still line with their name (no gem). The sight list leaves them out of
  *Nearby*; *Through time* shows them in their year among the sights, plainly:
  the year and name in grey, a stone badge, "Place of remembrance · not part
  of the game" and what the place remembers – no game state, no "NEW". They
  also have a tab of their own, *Remembrance* (below). Their symbol is a
  plain stone (not a flame, not a crescent).
* **Remembrance guide** (`RemembranceGuide`, `<city>-remembrance.json`,
  loaded by `CaptureModel.loadRemembrance`): the places of remembrance as a
  history lesson and a city walk, outside the game. Chapters (title, years, a
  paragraph) each list their places with a sentence on what each remembers;
  every place of remembrance is in exactly one chapter (tested). Tours are
  walks between places in an order that tells their history;
  `RemembranceGuide.length(of:)` gives the distance between the stops as the
  crow flies. The *Remembrance* tab (`RemembranceGuideView.swift`) shows an
  introduction, the chapters with their places (distance and – once you were
  there – when, no game states) and the walks (numbered stops, the distance,
  *Show the first place on the map*); no counts, no progress. A place's entry
  names its chapter (`RemembranceHeader`).
* **Photo capture** (`PhotoCapture`): a discovered sight is captured by
  photographing it there – the entry's *Take a photo* (or *Take a photo* in the
  discovery animation) opens the system camera when the sight is in view – the
  line of sight of the latest evaluated position (`AppModel.currentView`, at most
  two minutes old and 25 m away) shows it (`LineOfSightView.shows`) – or within
  the sight's extent plus 150 m of a recent position (`CaptureModel.canPhotograph`), flash off; the camera's
  own *Use Photo* keeps it (downscaled to 2048 px, JPEG) in
  `Captures/Photos/<data source>/<sight>-<milliseconds>.jpg`. Every photo is
  kept (`TakenPhoto`, `CaptureLog.album`): the first is the capture (its date
  counts, the animation plays "Captured!" with the photo in the medallion and
  the achievements it completes), later ones join the sight's photos. The entry
  shows the latest large and all of them in a row; a photo opens large, with
  when it was taken, *Share or save* and *Delete photo* (the sight stays
  captured; its record then shows the latest remaining photo). *Menu › Photos
  › All photos* shows every photo, newest first. *Save to the Photos app* (on
  by default) also adds each new photo to the iPhone's Photos, with where and
  when it was taken (`PhotoLibrary`, add-only access: MapQuest never reads the
  library; the menu says when access is denied).
  Only recording data sources capture; *Debug › Photograph sights from
  anywhere* lifts the distance check (and uses the photo library where there is
  no camera, e.g. the simulator). Discovering no longer counts for achievements;
  capturing does.
* **Stations** (`Station`, `TransitLine`, `StationCatalog`, `<city>-stations.json`;
  Berlin: docs/03-berlin-data.md): the U-Bahn and S-Bahn stations of a place are
  two stations (U and S Alexanderplatz), each with its lines; a line lists its
  stations in order. Extent 80 m (the circles must reach within 30 m). They are
  collected without a photo – walking past counts, so does riding through above
  ground (underground the GPS rarely works). A small notice over the map
  announces them ("Alexanderplatz collected · U2 · U5 · U8", or how many); a
  line completed plays the animation ("Line complete!"). On the 2D map
  collected stations are small signs below the sights – a blue square with
  "U", a green circle with "S" (their callout: lines and date); *Debug › Show
  all* shows the others in grey.
* **Log** (`CaptureLog`, `FileCaptureStore`): one JSON file per data source
  in `Application Support/MapQuest/Captures`, separate from the data stores:
  visits of sights (`records`, with whether their discovery was celebrated),
  photo captures (`photos`, one per captured sight, showing its latest photo),
  every photo taken (`album`) and collected stations (`stations`). Older logs
  without photos or stations load as they are; logs from before the album get
  one with their single photo per sight.
* **App** (`App/MapQuest/Capture`): `CaptureModel` re-checks the
  uncaptured sights (off the main thread) whenever the selected data source's
  discovered area changes. New captures of a recording data source are
  celebrated by `CaptureCelebrationView` – a golden medallion with the
  sight's icon bursts in over the dimmed screen with turning rays and flying
  sparks (haptic success; reduced motion: a fade); it ends after 4.5 s, a tap
  anywhere ends it at once. One capture at a time; more than three waiting
  (e.g. the first check of earlier discoveries) are celebrated together.
  View-only data sources record captures without celebrating.
* **Entries** (`SightInfo`, `<city>-sight-info.json`): every sight has an
  encyclopedia entry – the introduction of its Wikipedia article (English, or
  German where there is none: description and history) and its lead photo
  from Wikimedia Commons – locked until the sight is captured. Built by
  `Tools/capture/fetch_sight_info.py`: the sight's name and aliases are looked
  up as German article titles and accepted only if the article's coordinates
  lie near the sight (else a full-text search, same check); the English
  article via the language link; pronunciation notes removed, whole
  paragraphs up to about 1,400 characters; only free Commons photos (author
  and licence kept). Texts are CC BY-SA 4.0; each entry credits its article
  and photo. Photos are loaded when an entry is first opened and kept in
  `Caches/SightPhotos`.
* **History** (`SightHistory`, `<city>-sight-history.json`; `BerlinHistory`):
  each entry has a card *In history* – built (and opened, where that differs:
  e.g. a museum in an older building), architectural style, architects and
  artists, who commissioned it, **who ruled at the time** and the era (with a
  short summary), and for sights older than 1990 whether they lay in East or
  West Berlin – followed by the *History* section of its article (two
  paragraphs, *Read more* for the rest). Built by
  `Tools/capture/fetch_sight_history.py`: Wikidata (inception, opening,
  architect, style, commissioned by) and the article's infobox, overridden by
  the hand-checked table `Tools/capture/berlin_sight_history.csv` (Wikidata
  often has the founding year of an institution, not the date of its
  building; the table also gives the East/West sector); the history section
  as plain text (display templates expanded, references dropped), whole
  paragraphs up to about 1,800 characters. The ruler is not stored:
  `BerlinHistory` maps a year (read in July: in a year of succession the
  ruler of July counts) and the sector to the era – Slavic lands (before
  1157: an oak in Tegel is that old), Margraviate and Electorate of Brandenburg, Kingdom of Prussia, German Empire, Weimar
  Republic, Nazi Germany, Allied occupation, East Berlin (GDR) / West Berlin,
  reunified Germany – and its ruler: margraves, electors, kings and emperors,
  Reich presidents, the dictator, the Allied Kommandatura, the SED leaders in
  the East, the federal chancellors in the West and after 1990.
* **Photorealistic 3D or photo**: an entry shows 3D only where it is
  photorealistic – Apple's 3D city model (satellite imagery on 3D buildings
  and terrain, `MKImageryMapConfiguration(elevationStyle: .realistic)`) in
  cities flagged `City.hasPhotorealistic3D` (Berlin): an interactive view
  looking at the sight from above at an angle (drag, pinch, turn and tilt;
  kept within 1.5 km), its photo after the text. Elsewhere the entry opens
  with its photo. (Untextured LoD2 models were tried and dropped: not
  photorealistic.)
* **Discovery**: going there unlocks the entry ("Discovered!" in the
  animation, with when it was built and its era, *Take a photo* when you can,
  *Read entry* and *Show on map*); the sight's badge springs
  onto the 2D map with pulsing rings (when it is discovered while the map is
  shown, or when it first scrolls into view); its callout's info button opens
  the entry. Unopened entries are marked NEW in the list and by a dot on the
  trophy button (`CaptureLog.readEntries`). Celebrations wait while the list
  or an entry is open.
* **Views**: the captures at the bottom of the main screen (number of
  photographed sights, a dot for unread entries) open the list with three
  tabs – *Sights*, *Achievements*, *Remembrance* (`CaptureListView.Tab`, kept
  in `sightListTab`; a celebration's button opens the right one). *Sights*:
  the sights of the game, *Nearby* (nearest first) or *Through time*
  (by the year they were built, in sections per era with its years and
  summary; discovered ones show style and ruler) – discovered ones in orange
  (an orange ring and a camera: photograph it; filled and a seal once
  captured), the others in grey; tapping one opens its entry (or the locked
  page: distance and how to unlock it), both with *Show on map*. The header
  counts captured and discovered sights and collected stations. On the 2D map
  discovered sights are orange badges with their category icon and a camera
  mark, captured ones golden (annotations, above the fog; a callout gives name
  and state); *Debug › Show all sights* marks the others as grey "?". In 3D
  every sight in the scene floats as a turning gem on a beam – gold with its
  name once captured, orange once discovered, grey "?" otherwise – and the
  building of a captured sight is drawn in gold.

## Achievements

Goals made of sights (`MapQuestCore/Capture/Achievement.swift`,
`<city>-achievements.json`; Berlin has 102). Each has a group, title,
description, SF Symbol and a **rule** that picks its sights from the catalog
and the historical facts: categories (all churches, fountains, museums…),
the era of the year built (`BerlinHistory`, East and West apart), an
architect or client (compared without a note in parentheses, so “Hermann
Blankenstein (towers, 1878)” counts for Blankenstein), architectural styles,
a district, or an explicit list for themed stories (Museum Island, the Wall,
Spy City, Old Fritz…); `include`/`exclude` adjust a selection, `count`/`all`
are milestones (1, 10, 25, 50, 100, all captures). Sight achievements count
captured (photographed) sights. Rules, not lists: a sight
added to the catalog joins its era, district, category and architect without
editing the achievements. `AchievementBook` resolves them once (members
oldest first; rules picking fewer than two sights are left out) and derives
everything else from the capture log – nothing more is stored: progress,
completion (the date of the capture that reached the target), and which
achievements a capture **unlocks** (complete with it and every capture
celebrated before, not without it), shown in the capture animation.

* **Lines**: station rules (`places: stations`, `line`, `system`) pick
  stations: one achievement per line (U1–U9, every S-Bahn line; S41/S42 as the
  Ringbahn) with its stations in line order, every U-Bahn or S-Bahn station,
  and station milestones (1, 25, 100). Collected stations count at once – no
  photo. The achievement's page lists the line's stations in order, the
  nearest missing one first.
* **Groups**: Milestones, Collections (categories and curated sets: seats of
  power, town halls, border bridges, both zoos, clubs, live music), Stories
  (themed walks: World Heritage and its six housing estates, the airfields,
  Wedding…), Lines, Through time (one per era – none for the Nazi dictatorship
  and the occupation), Styles, Master builders (architects with at least three
  works; Friedrich Schulze's two parliaments as a story), and Districts (all
  twelve). Places of remembrance are in none (`AchievementBook` leaves them out
  of every rule, explicit lists and milestones included). Every other sight
  belongs to exactly one district achievement and – unless built 1933–1949 – one
  era achievement (tested; the oak from the Slavic era counts towards
  *Medieval Roots*).
* **Views**: the sight list's *Achievements* tab – the number completed, a
  filter (`AchievementFilter`: *All*, *Completed*, *Started*, *Not started*;
  kept in `achievementFilter`), "Almost there" (the three started ones with
  the fewest sights to go; with *All* and *Started*), then the groups with
  medals (gold when complete, a progress ring otherwise; the header counts
  the whole group). An achievement's
  page shows its description, progress or completion date, *Next up* (the
  nearest sight still missing, with *Show on map*) and its sights by year.
  Each entry lists the achievements its sight counts towards (also when
  locked, as an incentive).

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
| `App/MapQuest/Location/LocationTracker.swift` | `CLLocationManager` wrapper: permission, continuous updates (also in the background), low power while still in the background, significant-change relaunch |
| `App/MapQuest/AppModel.swift` | Writes every fix to the track and streams fixes through the `LocationRecorder`, owns the selected data source, publishes snapshots and statistics, refreshes areas when building data changes |
| `App/MapQuest/ViewOptions.swift`, `Views/MapViewSettingsView.swift` | Viewing options: 2D or 3D, fog of war or heatmap, the layer, all time or a day/week/month/year (computed in the background, live while the period includes now), the map style |
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
| `App/MapQuest/Localization/LanguageSettings.swift`, `MapQuestKit/Sources/MapQuestCore/Localization/*` | The app's language (System, English, German), `tr`/`trn`, bilingual names ([docs/08](08-localization.md)) |
| `App/MapQuest/Views/*` | Main screen (map, menu button, the note on what the map shows, captures and tracking at the bottom), the menu and its pages (`SettingsView`), statistics, districts |

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
* **User marker** at eye height; with *Debug › Show evaluation details* the
  HUD shows the estimated eye height, the resulting view distance and the
  number of buildings.
* Orbit/pan/zoom via SceneKit's camera controller; recolouring runs off the
  main thread whenever the layer changes.

SceneKit was chosen for its built-in camera control; the mesh code is
renderer-independent, so a later move to RealityKit only replaces
`SceneKitMesh.swift` and `Map3DView.swift`.

### Debug settings

The debug panel tunes parameters on the device. It is a sheet over the map
(*menu › Developer › Debug settings*) with three heights; at the small and medium heights the map above
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
  Caching is layered so that zooming in and out does not wait:
  * **Finished pieces** (base map with fog) are kept per map rectangle and
    zoom scale (`PieceCache`, 128 MB, least recently used first): MapKit asks
    for the same pieces whenever the map returns to a zoom level, and they are
    drawn from there instead of being composed, blurred and fogged again. A
    piece is kept only when all its tiles were there; a change of the
    discovered area forgets only the pieces it touches (the same rectangles
    that are redrawn), a change of style or base map all of them, a memory
    warning too.
  * **Drawn tiles** are kept in memory (160 MB) and on disk as PNG in
    `Caches/MapQuest/DrawnTiles/v<drawing version>/<style>` (300 MB, oldest
    first out; the system may purge them, they are drawn again). A drawn tile
    older than its map data is drawn again; raising
    `BaseMapTiles.drawingVersion` drops all of them when the drawing changes.
  * **Decoded data tiles**: 48 in memory (one z14 tile draws every deeper level
    of its area).
  * **Prefetching**: half a second after the map comes to rest, the tiles one
    level deeper and one and two levels coarser (twice and four times the area
    on screen) are prepared in the background – map data downloaded (at most
    12 tiles per pass, one after the other), tiles drawn and written to disk;
    moving the map again ends the pass.

  *menu › Map data* shows the size of map data and drawn tiles and deletes both.
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
