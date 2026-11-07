# MapQuest – Architecture

The rationale for the choices below is in the
[literature review](01-literature-review.md).

## Code layout

| Path | Contents | Platforms |
|---|---|---|
| `MapQuestKit/` | Swift package with all platform-independent logic | iOS, macOS, Linux |
| `MapQuestKit/Sources/MapQuestCore` | Geo primitives, data model, store protocols, discovery | |

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

Every store implementation is verified against the same contract tests
(`DataStoreContract` in the test target).
