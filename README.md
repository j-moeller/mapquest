# MapQuest

MapQuest is an iPhone app that combines a classic map with a *fog of war*:
you only see the parts of the world you have actually been to. Everything
else stays visibly darker until you go there. The first play area is
Berlin; the data model is global.

The app has three major components:

| Component | Responsibility |
|---|---|
| **Location tracking** | Continuously observes the user's position, but stores only the positions that reveal new parts of the map (latitude, longitude, height, timestamp) |
| **Discovered area** | Turns stored positions into discovered-area polygons, merges adjacent areas into regions, keeps disconnected areas apart; it is a cache that can always be rebuilt from the positions |
| **Map display** | 2D: MapKit with a translucent fog overlay and the discovered area cut out. 3D: buildings that block the view; seen buildings are revealed |

## How it works

1. **Tracking** – `LocationTracker` receives every Core Location fix (also in
   the background). The `LocationRecorder` drops inaccurate fixes and fixes
   outside Berlin, asks every discovery layer how much *new* area the fix
   would reveal, and stores the fix only if that is ≥ 10 % (or ≥ 2 000 m²).
   Walking through known streets stores nothing; standing still is not even
   evaluated.
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
     viewpoints see over lower roofs and further.
4. **Maps** – 2D: MapKit with a translucent fog overlay, discovered pieces cut
   out. 3D: SceneKit city model, buildings coloured by discovery, fogged map
   on the ground.

## Using the app

* First launch explains the purpose and asks for location access; upgrading
  to *Always* keeps discovering in the background.
* **2D / 3D** switch at the top; in 2D the *Radius / Line of sight* picker
  chooses the layer.
* The panel shows discovered area, share of Berlin, regions and stored
  positions; tap the chevron to collapse it on small screens (iPhone 13 mini).
* **Settings** switch the data source (*My discoveries*, *Sandbox (testing)*,
  the view-only *Demo explorer*, or a **remote account** on a MapQuest server
  backed by PostgreSQL), show per-district coverage, rebuild the discovered
  area, pause recording or delete data.
* **Settings › Debug settings** tune everything on the fly: fog opacity,
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

```bash
xcodegen generate
```

```bash
open MapQuest.xcodeproj
```

Select your development team for the `MapQuest` target (and change the bundle
identifier `com.example.MapQuest` if needed), then run on an iPhone or in the
Simulator. In the Simulator the scheme replays a walk from the Brandenburger
Tor to Alexanderplatz (`App/Simulation/BerlinWalk.gpx`).

The platform-independent core can be built and tested without Xcode, also on Linux:

```bash
cd MapQuestKit && swift test
```

## Repository layout

| Path | Contents |
|---|---|
| `MapQuestKit/` | Swift package: data model, SQLite store, Clipper2 polygon engine, discovery |
| `App/MapQuest/` | The iOS app (SwiftUI, MapKit, Core Location) |
| `App/Simulation/` | GPX walks for the iOS Simulator |
| `Tools/` | Data preparation scripts (Berlin data, app icon) |
| `Server/` | Remote store: PostgreSQL schema and reference REST server |
| `docs/` | Literature review, architecture, data sources |
| `project.yml` | XcodeGen project specification |

## Documentation

* [Literature review and design decisions](docs/01-literature-review.md)
* [Architecture](docs/02-architecture.md)
* [Berlin data](docs/03-berlin-data.md)
* [Remote store (PostgreSQL)](docs/04-remote-store.md)

## Status

- [x] Literature review
- [x] Data model (location data) for 2D + 3D
- [x] Location data component and discovered-area component (2D)
- [x] 2D map presentation
- [x] Berlin 2D data
- [x] Location data component and discovered-area component (3D)
- [x] 3D map presentation
- [x] Berlin 3D data (on-demand OSM downloads; full Berlin database built by CI)

## Known limitations and next steps

* **Terrain** comes from Berlin's official 1 m terrain model at ≈ 30 m
  resolution; outside Berlin the ground is assumed flat.
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
