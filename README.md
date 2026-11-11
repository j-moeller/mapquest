# MapQuest

MapQuest is an iPhone app that combines a classic map with a *fog of war*:
you only see the parts of the world you have actually been to. Everything
else stays visibly darker until you go there. It works everywhere, on a map
without labels or icons, drawn on the phone from OpenStreetMap data
(OpenFreeMap vector tiles, cached for offline use) – only city and district
names are written, above the fog. Berlin, Braunschweig and Peine
additionally have bundled 3D building and terrain data for the line-of-sight
reveal.

The app has four major components:

| Component | Responsibility |
|---|---|
| **Location tracking** | Records the position about once per second in a compact track (≈ 6 bytes per fix); the positions that reveal new parts of the map drive the fog of war |
| **Discovered area** | Turns stored positions into discovered-area polygons, merges adjacent areas into regions, keeps disconnected areas apart; it is a cache that can always be rebuilt from the positions |
| **Capture** | 119 Berlin sights (all districts) are captured once you have been there (the radius view covers them): a capture animation, a list of available and captured sights, golden badges on the map and gems in 3D |
| **Map display** | 2D: a label-free base map with a black fog (80 %, blurred map underneath) drawn into it, the discovered area cut out. 3D: buildings that block the view; seen buildings are revealed |

## How it works

1. **Tracking** – `LocationTracker` receives every Core Location fix (also in
   the background). Every fix goes into the **track** (delta-encoded segments,
   ≈ 6 bytes per fix: ≈ 15 MB per year for two hours a day, ≈ 190 MB around
   the clock). A **coverage sampler** picks the few fixes that matter for the
   area – about one per 10 m of movement, none while standing still – and the
   `LocationRecorder` asks every discovery layer how much *new* area they
   reveal; fixes revealing ≥ 10 % (or ≥ 2 000 m²) become key samples.
2. **Storage** – one SQLite database per data source holds the location
   samples (lat, lon, altitude, accuracies, timestamp, tile key) *and* the
   discovered area. Everything goes through the `MapQuestDataStore`
   protocol, so a remote store or another user's database can replace it.
3. **Discovered area** – a `DiscoveryEngine` per layer merges the revealed
   area into polygons (Clipper2, integer Web Mercator coordinates), clipped
   into 372 m tiles, and tracks connected **regions**: adjacent areas merge,
   disconnected ones (another district, another city) stay separate. Layers
   are caches and can be rebuilt from the samples at any time.
   * **Radius (2D)**: a 50 m circle per sample.
   * **Line of sight (3D)**: 720-ray casting against OpenStreetMap buildings;
     buildings you see are discovered and hide what is behind them; higher
     viewpoints see over lower roofs and further. Where no building data is
     available yet (a new city, offline), the radius circle – the default
     map – is used instead.
   * **When building data arrives** (downloaded, or a newer bundled dataset),
     exactly the areas whose view it can change are recomputed from the
     stored positions; everything else stays cached
     ([docs/05](docs/05-cache-invalidation.md)).
4. **Maps** – 2D: map tiles drawn on the phone from cached OpenStreetMap
   vector data, without labels, with the fog drawn into them
   piece by piece inside MapKit's own rendering (80 % black, blurred map
   underneath, soft edges), so the fog cannot glide over the map; city and
   district names above the fog. 3D: SceneKit city model, buildings coloured
   by discovery, fogged map on the ground.

## Using the app

* First launch explains the purpose and asks for location access; upgrading
  to *Always* keeps discovering in the background.
* **2D / 3D** switch at the top, next to the view bar: fog of war or heatmap,
  and *All time / Day / Week / Month / Year* with ‹ › to step through
  periods; in 2D the *Radius / Line of sight* picker chooses the layer.
* The panel shows discovered area, share of the current city, regions and stored
  positions; tap the chevron to collapse it on small screens (iPhone 13 mini).
* **Sights**: walk up to one of 119 Berlin sights – until the circles of the
  radius view cover it – and it is captured, with an animation (tap to skip):
  it appears on your map and unlocks its entry – a photorealistic 3D view
  (Apple's 3D city model, where available) or its photo, description and
  history (from Wikipedia and Wikimedia Commons), with its place in Berlin's
  history: when it was built and opened, its style, its architects, who
  commissioned it, who ruled Berlin then and in which era. The trophy button
  in the panel lists all sights, nearest first or *Through time* (by year, in
  Berlin's eras) – captured ones in orange, the others in grey; tap one to
  see it on the map. Captured sights are golden badges on the map and golden buildings
  with floating gems in 3D. *Debug › Show all sights* marks the uncaptured
  ones too.
* **Settings** switch the data source (*My discoveries*, *Sandbox (testing)*,
  the view-only *Demo explorer*, or a **remote account** on a MapQuest server
  backed by PostgreSQL), show per-district coverage, rebuild the discovered
  area, pause recording or delete data. **Building data** shows which
  explored areas have bundled, downloaded or no building data, turns
  automatic OpenStreetMap downloads on or off, and downloads missing data
  for areas that were computed with the default map.
* **Debug settings** (slider button on the map, or Settings › Developer) open
  as a panel over the map, which stays visible and usable while tuning
  everything on the fly: fog opacity (up to 100 %), blur under the fog,
  soft fog edges and the base map style (streets, light, dark),
  radius, rays and sight distances of the line of sight, terrain on/off,
  recording thresholds. *Long-press the 2D map* (or "Place a test position
  here") to record a test position with a chosen eye height – e.g. 120 m to
  try the "high point" behaviour without climbing a tower. Use the *Sandbox*
  data source for experiments.

## Getting started

Requirements: Xcode 15 or newer (iOS 17 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
```

Once, put your signing settings in a local file that `xcodegen generate` never
touches (git-ignored), then fill in your team ID and bundle ID prefix:

```bash
cp App/Config/Local.xcconfig.example App/Config/Local.xcconfig
```

```bash
xcodegen generate
```

```bash
open MapQuest.xcodeproj
```

The project is generated from `project.yml` and is not committed: run
`xcodegen generate` again after pulling changes that add or remove files, and
keep settings in `project.yml` or `Local.xcconfig` rather than in Xcode, where
they would be lost. Then run on an iPhone or in the Simulator. The scheme
simulates no location; while the app runs, Xcode's *Debug › Simulate
Location* can replay a walk from the Brandenburger Tor to Alexanderplatz
(`App/Simulation/BerlinWalk.gpx`).

The platform-independent core can be built and tested without Xcode, also on Linux:

```bash
cd MapQuestKit && swift test
```

The repository has no hosted CI. Before a release, check on a Mac:

```bash
xcodebuild build -project MapQuest.xcodeproj -scheme MapQuest -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

```bash
Tools/check_bundle.sh
```

The UI smoke test (`App/MapQuestUITests`, iPhone 13 mini) runs from Xcode
(*Product › Test*); the remote-store tests need a running server
([docs/04](docs/04-remote-store.md)). The bundled city data is rebuilt with
`Tools/berlin/build_buildings.sh` and `Tools/cities/build_city.sh`.

## Repository layout

| Path | Contents |
|---|---|
| `MapQuestKit/` | Swift package: data model, SQLite store, Clipper2 polygon engine, discovery |
| `App/MapQuest/` | The iOS app (SwiftUI, MapKit, Core Location) |
| `App/Simulation/` | GPX walks for the iOS Simulator |
| `Tools/` | Data preparation scripts (Berlin and Lower Saxony city data, app icon) |
| `Server/` | Remote store: PostgreSQL schema and reference REST server |
| `docs/` | Literature review, architecture, data sources |
| `project.yml` | XcodeGen project specification |

## Documentation

* [Literature review and design decisions](docs/01-literature-review.md)
* [Architecture](docs/02-architecture.md)
* [Berlin data](docs/03-berlin-data.md)
* [Remote store (PostgreSQL)](docs/04-remote-store.md)
* [Cache invalidation when map data improves](docs/05-cache-invalidation.md)
* [Braunschweig data](docs/06-braunschweig-data.md)
* [Peine data](docs/07-peine-data.md)

## Status

- [x] Literature review
- [x] Data model (location data) for 2D + 3D
- [x] Location data component and discovered-area component (2D)
- [x] 2D map presentation
- [x] Berlin 2D data
- [x] Location data component and discovered-area component (3D)
- [x] 3D map presentation
- [x] Berlin 3D data (bundled database, `Tools/berlin/build_buildings.sh`)
- [x] Cache invalidation when building data improves (docs/05)
- [x] Continuous 1 Hz track, coverage sampling, time-based views, heatmap
- [x] Braunschweig as a second city (docs/06)
- [x] Fog of war everywhere; 3D data downloads only around the bundled cities
- [x] Peine as a third city, from official data only (docs/07)
- [x] Capture component: Berlin sights captured by uncovering them

## Known limitations and next steps

* **Terrain** comes from Berlin's official 1 m terrain model at ≈ 30 m
  resolution (Braunschweig and Peine: LGLN DGM1); elsewhere positions count
  as street level.
* **Building heights** come from Berlin's LoD2 models where they match an OSM
  footprint, otherwise from OSM tags or estimates.
* **Remote store**: PostgreSQL behind a small REST API works for viewing
  and recording, but recording needs a connection for every stored
  position; offline-first sync is the next step (see docs/04).
* The discovered area of a data source is loaded into memory completely,
  which is fine for a city; a world-scale dataset would need viewport-based
  loading.
* **Timeline**: samples and pieces carry timestamps; a timeline view
  (replaying samples through the engines) is a natural next feature.
* SceneKit was used for its built-in camera control; the mesh generation is
  renderer-independent if a move to RealityKit is wanted.
