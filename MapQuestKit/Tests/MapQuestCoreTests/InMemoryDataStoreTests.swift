import XCTest
@testable import MapQuestCore

/// Behaviour every `MapQuestDataStore` must have. Concrete store tests call these.
enum DataStoreContract {
    static let start = Date(timeIntervalSince1970: 1_750_000_000)

    static func makeSamples() -> [LocationSample] {
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

    static func verifyLocationStore(_ store: some LocationStore, file: StaticString = #filePath, line: UInt = #line) async throws {
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

    static func makePiece(layer: DiscoveryLayerID, region: UUID, tileX: Int, firstDiscovered: Date) -> DiscoveredPiece {
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

    static func verifyDiscoveredAreaStore(_ store: some DiscoveredAreaStore, file: StaticString = #filePath, line: UInt = #line) async throws {
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

        try await store.replaceLayer(layer, with: [b1])
        pieces = try await store.pieces(layer: layer, tiles: nil)
        XCTAssertEqual(pieces.map(\.id), [b1.id], file: file, line: line)

        try await store.removeAllPieces(layer: layer)
        pieces = try await store.pieces(layer: layer, tiles: nil)
        XCTAssertTrue(pieces.isEmpty, file: file, line: line)
        let remainingLayers = try await store.layers()
        XCTAssertEqual(remainingLayers, [other], file: file, line: line)
    }
}

final class InMemoryDataStoreTests: XCTestCase {
    func testLocationStoreContract() async throws {
        try await DataStoreContract.verifyLocationStore(InMemoryDataStore())
    }

    func testDiscoveredAreaStoreContract() async throws {
        try await DataStoreContract.verifyDiscoveredAreaStore(InMemoryDataStore())
    }

    func testChangeSetAppendKeepsSequentialSemantics() async throws {
        let layer: DiscoveryLayerID = "l"
        let r1 = UUID(), r2 = UUID()
        let p1 = DataStoreContract.makePiece(layer: layer, region: r1, tileX: 1, firstDiscovered: DataStoreContract.start)
        let p2 = DataStoreContract.makePiece(layer: layer, region: r2, tileX: 2, firstDiscovered: DataStoreContract.start)
        let p3 = DataStoreContract.makePiece(layer: layer, region: r1, tileX: 3, firstDiscovered: DataStoreContract.start)

        var combined = DiscoveredAreaChangeSet(layer: layer, upsertedPieces: [p1, p2])
        combined.append(DiscoveredAreaChangeSet(
            layer: layer, regionMerges: [.init(sources: [r1], target: r2)], removedPieceIDs: [p2.id], upsertedPieces: [p3]
        ))

        let sequential = InMemoryDataStore()
        await sequential.apply(DiscoveredAreaChangeSet(layer: layer, upsertedPieces: [p1, p2]))
        await sequential.apply(DiscoveredAreaChangeSet(
            layer: layer, regionMerges: [.init(sources: [r1], target: r2)], removedPieceIDs: [p2.id], upsertedPieces: [p3]
        ))
        let batched = InMemoryDataStore()
        await batched.apply(combined)

        let expected = await sequential.pieces(layer: layer, tiles: nil)
        let actual = await batched.pieces(layer: layer, tiles: nil)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.map(\.regionID), [r2, r1], "p1 relabelled to r2, p3 keeps r1")
    }
}
