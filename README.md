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
| `docs/` | Literature review, architecture, data sources |
| `project.yml` | XcodeGen project specification |

## Documentation

* [Literature review and design decisions](docs/01-literature-review.md)
* [Architecture](docs/02-architecture.md)
* [Berlin data](docs/03-berlin-data.md)

## Status

- [x] Literature review
- [x] Data model (location data) for 2D + 3D
- [x] Location data component and discovered-area component (2D)
- [x] 2D map presentation
- [x] Berlin 2D data
- [ ] Location data component and discovered-area component (3D)
- [ ] 3D map presentation
- [ ] Berlin 3D data
