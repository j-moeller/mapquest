import Foundation
import XCTest
import MapQuestCore

/// Behaviour every `MapQuestDataStore` must have. Concrete store tests call these.
public enum DataStoreContract {
    public static let start = Date(timeIntervalSince1970: 1_750_000_000)

    public static func makeSamples() -> [LocationSample] {
        // A short walk along Unter den Linden plus one sample in Hamburg.
        var samples: [LocationSample] = (0..<10).map { i in
            LocationSample(
                latitude: 52.5170, longitude: 13.3800 + Double(i) * 0.001, altitude: 36 + Double(i),
                horizontalAccuracy: 5, verticalAccuracy: 3, timestamp: start.addingTimeInterval(Double(i) * 10)
            )
        }
        samples.append(LocationSample(
            latitude: 53.5511, longitude: 9.9937, altitude: 8, horizontalAccuracy: 5, verticalAccuracy: 3,
            timestamp: start.addingTimeInterval(3_600)
        ))
        return samples
    }

    public static func verifyLocationStore(_ store: some LocationStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        let samples = makeSamples()
        try await store.addSamples(samples.shuffled())
        var count = try await store.sampleCount()
        XCTAssertEqual(count, samples.count, file: file, line: line)

        // Re-adding the same IDs replaces instead of duplicating.
        var modified = samples[0]
        modified.altitude = 99
        try await store.addSamples([modified])
        count = try await store.sampleCount()
        XCTAssertEqual(count, samples.count, file: file, line: line)

        let all = try await store.samples(matching: .all)
        XCTAssertEqual(all.map(\.id), samples.map(\.id), "chronological order", file: file, line: line)
        XCTAssertEqual(all[0].altitude, 99, file: file, line: line)
        XCTAssertEqual(all[1], samples[1], "all fields round-trip", file: file, line: line)

        let reversed = try await store.samples(matching: LocationQuery(order: .reverseChronological, limit: 2))
        XCTAssertEqual(reversed.map(\.id), [samples[10].id, samples[9].id], file: file, line: line)

        let berlin = GeoBoundingBox(minLatitude: 52.3, minLongitude: 13.0, maxLatitude: 52.7, maxLongitude: 13.8)
        let inBerlin = try await store.samples(matching: .within(berlin))
        XCTAssertEqual(inBerlin.count, 10, file: file, line: line)

        let small = GeoBoundingBox(center: samples[3].coordinate, radius: 30)
        let near = try await store.samples(matching: .within(small))
        XCTAssertEqual(near.map(\.id), [samples[3].id], file: file, line: line)

        let window = try await store.samples(matching: LocationQuery(from: start.addingTimeInterval(20), to: start.addingTimeInterval(50)))
        XCTAssertEqual(window.map(\.id), Array(samples[2..<5]).map(\.id), file: file, line: line)

        try await store.removeAllSamples()
        count = try await store.sampleCount()
        XCTAssertEqual(count, 0, file: file, line: line)
    }

    public static func makePiece(layer: DiscoveryLayerID, region: UUID, tileX: Int, firstDiscovered: Date) -> DiscoveredPiece {
        let tile = TileKey(zoom: DiscoveryGrid.zoom, x: tileX, y: 21_500)
        let o = tile.origin
        let polygon = WorldPolygon(exterior: [
            WorldPoint(x: o.x + 100, y: o.y + 100), WorldPoint(x: o.x + 900, y: o.y + 100),
            WorldPoint(x: o.x + 900, y: o.y + 900), WorldPoint(x: o.x + 100, y: o.y + 900),
        ])
        return DiscoveredPiece(
            layer: layer, regionID: region, tile: tile, polygon: polygon,
            areaSquareMeters: polygon.areaSquareMeters, firstDiscovered: firstDiscovered, lastUpdated: firstDiscovered
        )
    }

    public static func verifyDiscoveredAreaStore(_ store: some DiscoveredAreaStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        let layer: DiscoveryLayerID = "test-layer"
        let other: DiscoveryLayerID = "other-layer"
        let regionA = UUID(), regionB = UUID()
        let a1 = makePiece(layer: layer, region: regionA, tileX: 35_200, firstDiscovered: start)
        let a2 = makePiece(layer: layer, region: regionA, tileX: 35_201, firstDiscovered: start.addingTimeInterval(5))
        let b1 = makePiece(layer: layer, region: regionB, tileX: 35_210, firstDiscovered: start.addingTimeInterval(10))
        let o1 = makePiece(layer: other, region: UUID(), tileX: 35_200, firstDiscovered: start)

        try await store.apply(DiscoveredAreaChangeSet(layer: layer, upsertedPieces: [a1, a2, b1]))
        try await store.apply(DiscoveredAreaChangeSet(layer: other, upsertedPieces: [o1]))

        var pieces = try await store.pieces(layer: layer, tiles: nil)
        XCTAssertEqual(Set(pieces.map(\.id)), [a1.id, a2.id, b1.id], file: file, line: line)
        XCTAssertEqual(pieces.first { $0.id == a1.id }, a1, "all fields round-trip", file: file, line: line)

        let layers = try await store.layers()
        XCTAssertEqual(Set(layers), [layer, other], file: file, line: line)

        let range = TileRange(zoom: DiscoveryGrid.zoom, minX: 35_200, minY: 21_500, maxX: 35_200, maxY: 21_500)
        pieces = try await store.pieces(layer: layer, tiles: range)
        XCTAssertEqual(pieces.map(\.id), [a1.id], file: file, line: line)

        var regions = try await store.regions(layer: layer)
        XCTAssertEqual(regions.map(\.id), [regionA, regionB], file: file, line: line)
        XCTAssertEqual(regions[0].pieceCount, 2, file: file, line: line)
        XCTAssertEqual(regions[0].areaSquareMeters, a1.areaSquareMeters + a2.areaSquareMeters, accuracy: 1e-6, file: file, line: line)

        // Merge B into A, replace a2 by a grown piece.
        var grown = makePiece(layer: layer, region: regionA, tileX: 35_201, firstDiscovered: a2.firstDiscovered)
        grown.polygon.exterior[2].x += 50
        grown.lastUpdated = start.addingTimeInterval(100)
        try await store.apply(DiscoveredAreaChangeSet(
            layer: layer,
            regionMerges: [.init(sources: [regionB], target: regionA)],
            removedPieceIDs: [a2.id],
            upsertedPieces: [grown]
        ))
        regions = try await store.regions(layer: layer)
        XCTAssertEqual(regions.map(\.id), [regionA], file: file, line: line)
        XCTAssertEqual(regions[0].pieceCount, 3, file: file, line: line)
        XCTAssertEqual(regions[0].lastUpdated, grown.lastUpdated, file: file, line: line)
        XCTAssertEqual(regions[0].tiles.minX, 35_200, file: file, line: line)
        XCTAssertEqual(regions[0].tiles.maxX, 35_210, file: file, line: line)

        // Other layers are untouched.
        let otherPieces = try await store.pieces(layer: other, tiles: nil)
        XCTAssertEqual(otherPieces, [o1], file: file, line: line)

        // Data watermarks: set with change sets (atomically with pieces), per layer.
        let dataTile = TileKey(zoom: DataGrid.zoom, x: 8_800, y: 5_373)
        let neighbour = TileKey(zoom: DataGrid.zoom, x: 8_801, y: 5_373)
        try await store.apply(DiscoveredAreaChangeSet(layer: layer, dataVersions: [dataTile: DataGrid.noData, neighbour: "download:1"]))
        try await store.apply(DiscoveredAreaChangeSet(layer: layer, dataVersions: [dataTile: "download:2"]))
        try await store.apply(DiscoveredAreaChangeSet(layer: other, dataVersions: [dataTile: "bundle:7"]))
        var versions = try await store.dataVersions(layer: layer)
        XCTAssertEqual(versions, [dataTile: "download:2", neighbour: "download:1"], file: file, line: line)

        try await store.replaceLayer(layer, with: [b1], dataVersions: [neighbour: "download:3"])
        pieces = try await store.pieces(layer: layer, tiles: nil)
        XCTAssertEqual(pieces.map(\.id), [b1.id], file: file, line: line)
        versions = try await store.dataVersions(layer: layer)
        XCTAssertEqual(versions, [neighbour: "download:3"], "replacing a layer replaces its watermarks", file: file, line: line)

        try await store.removeAllPieces(layer: layer)
        pieces = try await store.pieces(layer: layer, tiles: nil)
        XCTAssertTrue(pieces.isEmpty, file: file, line: line)
        let remainingLayers = try await store.layers()
        XCTAssertEqual(remainingLayers, [other], file: file, line: line)
        versions = try await store.dataVersions(layer: layer)
        XCTAssertTrue(versions.isEmpty, file: file, line: line)
        let otherVersions = try await store.dataVersions(layer: other)
        XCTAssertEqual(otherVersions, [dataTile: "bundle:7"], file: file, line: line)
    }

    /// A walk at 1 Hz along Unter den Linden: `count` fixes from `start`.
    public static func makeTrack(count: Int, from start: Date = DataStoreContract.start, longitude: Double = 13.3800) -> [TrackPoint] {
        (0..<count).map { i -> TrackPoint in
            let t = Double(i)
            let latitude: Double = 52.5170 + sin(t / 40) * 0.0002
            let east: Double = longitude + t * 0.00002
            let altitude: Double = 36 + Double(i % 7) * 0.3
            let accuracy: Double = 4 + Double(i % 3)
            return TrackPoint(
                timestamp: start.addingTimeInterval(t), latitude: latitude, longitude: east,
                altitude: altitude, horizontalAccuracy: accuracy, verticalAccuracy: 3
            )
        }
    }

    public static func verifyTrackStore(_ store: some TrackStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await store.removeAllTrack()
        let walk = makeTrack(count: 300)
        let first = TrackSegment(points: Array(walk[0..<100]))
        var second = TrackSegment(points: Array(walk[100..<150]))
        try await store.putTrackSegments([first, second])
        // The open segment grows and is rewritten under the same ID.
        second = TrackSegment(id: second.id, points: Array(walk[100..<300]))
        try await store.putTrackSegments([second])

        let summary = try await store.trackSummary()
        XCTAssertEqual(summary.segmentCount, 2, file: file, line: line)
        XCTAssertEqual(summary.pointCount, 300, file: file, line: line)
        XCTAssertEqual(summary.byteCount, first.data.count + second.data.count, file: file, line: line)
        XCTAssertEqual(summary.first, walk[0].timestamp, file: file, line: line)
        XCTAssertEqual(summary.last, walk[299].timestamp, file: file, line: line)

        let all = try await store.trackPoints()
        XCTAssertEqual(all, walk, "every fix round-trips exactly", file: file, line: line)

        // Time filter: segments overlapping, points inside.
        let interval = DateInterval(start: walk[90].timestamp, end: walk[110].timestamp)
        let segments = try await store.trackSegments(overlapping: interval, intersecting: nil)
        XCTAssertEqual(segments.map(\.id), [first.id, second.id], file: file, line: line)
        let points = try await store.trackPoints(in: interval)
        XCTAssertEqual(points, Array(walk[90...110]), file: file, line: line)
        let later = try await store.trackSegments(
            overlapping: DateInterval(start: walk[200].timestamp, end: walk[299].timestamp.addingTimeInterval(60)), intersecting: nil
        )
        XCTAssertEqual(later.map(\.id), [second.id], file: file, line: line)

        // Spatial filter.
        let east = WorldRect(bounding: walk[250..<300].map(\.worldPoint))!
        let nearEast = try await store.trackSegments(overlapping: nil, intersecting: east)
        XCTAssertEqual(nearEast.map(\.id), [second.id], file: file, line: line)
        let far = WebMercator.worldRect(for: GeoBoundingBox(center: GeoCoordinate(latitude: 53.55, longitude: 9.99), radius: 100))
        let none = try await store.trackSegments(overlapping: nil, intersecting: far)
        XCTAssertTrue(none.isEmpty, file: file, line: line)

        try await store.removeAllTrack()
        let empty = try await store.trackSummary()
        XCTAssertEqual(empty.pointCount, 0, file: file, line: line)
        XCTAssertNil(empty.first, file: file, line: line)
    }
}
