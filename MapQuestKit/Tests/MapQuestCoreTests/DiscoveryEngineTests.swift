import XCTest
@testable import MapQuestCore

/// Helpers to place samples by metric offsets from a reference point in Berlin.
enum Walk {
    static let origin = GeoCoordinate(latitude: 52.520_0, longitude: 13.405_0) // near Alexanderplatz
    static let start = Date(timeIntervalSince1970: 1_760_000_000)

    static func coordinate(east: Double, north: Double, from base: GeoCoordinate = origin) -> GeoCoordinate {
        GeoCoordinate(
            latitude: base.latitude + north / 111_320,
            longitude: base.longitude + east / (111_320 * cos(base.latitude * .pi / 180))
        )
    }

    static func sample(east: Double, north: Double, second: Double, from base: GeoCoordinate = origin, accuracy: Double = 5) -> LocationSample {
        LocationSample(
            coordinate: coordinate(east: east, north: north, from: base), altitude: 40,
            horizontalAccuracy: accuracy, verticalAccuracy: 4, timestamp: start.addingTimeInterval(second)
        )
    }

    /// Samples every `step` metres along a straight line.
    static func line(fromEast e0: Double, north n0: Double, toEast e1: Double, north n1: Double, step: Double, startSecond: Double = 0, base: GeoCoordinate = origin) -> [LocationSample] {
        let length = ((e1 - e0) * (e1 - e0) + (n1 - n0) * (n1 - n0)).squareRoot()
        let count = max(Int((length / step).rounded(.up)), 1)
        return (0...count).map { i in
            let t = Double(i) / Double(count)
            return sample(east: e0 + (e1 - e0) * t, north: n0 + (n1 - n0) * t, second: startSecond + Double(i), from: base)
        }
    }
}

final class DiscoveryEngineTests: XCTestCase {
    let model = CircleDiscoveryModel(radius: 50)

    func makeEngine(store: any MapQuestDataStore = InMemoryDataStore()) -> DiscoveryEngine {
        DiscoveryEngine(model: model, store: store)
    }

    func testCircleModelAreaAndLayer() {
        let polygon = model.circle(around: Walk.origin)
        XCTAssertEqual(polygon.areaSquareMeters, .pi * 50 * 50, accuracy: .pi * 50 * 50 * 0.003)
        XCTAssertEqual(model.layer, "circle-50m")
    }

    func testFirstSampleIsEntirelyNewAndSecondVisitIsKnown() async throws {
        let engine = makeEngine()
        let sample = Walk.sample(east: 0, north: 0, second: 0)
        let first = try await engine.evaluate(sample)
        XCTAssertEqual(first.newAreaFraction, 1, accuracy: 1e-6)
        XCTAssertEqual(first.revealedAreaSquareMeters, .pi * 2_500, accuracy: 25)
        try await engine.commit(first)

        let again = try await engine.evaluate(Walk.sample(east: 0, north: 0, second: 10))
        XCTAssertEqual(again.newAreaSquareMeters, 0, accuracy: 1)

        // Moving 10 m reveals about 12.7 % of a 50 m disk (lens geometry).
        let moved = try await engine.evaluate(Walk.sample(east: 10, north: 0, second: 20))
        XCTAssertEqual(moved.newAreaFraction, 0.127, accuracy: 0.01)

        let insideDiscovered = try await engine.isDiscovered(Walk.coordinate(east: 30, north: 0))
        XCTAssertTrue(insideDiscovered)
        let outside = try await engine.isDiscovered(Walk.coordinate(east: 80, north: 0))
        XCTAssertFalse(outside)
    }

    func testWalkCreatesOneRegionAcrossTileBorders() async throws {
        let store: any MapQuestDataStore = InMemoryDataStore()
        let engine = makeEngine(store: store)
        // 1.5 km walk eastwards crosses several 372 m tiles.
        let samples = Walk.line(fromEast: 0, north: 0, toEast: 1_500, north: 0, step: 20)
        for sample in samples { try await engine.process(sample) }

        let regions = try await store.regions(layer: model.layer)
        XCTAssertEqual(regions.count, 1)
        let pieces = try await store.pieces(layer: model.layer, tiles: nil)
        XCTAssertGreaterThan(Set(pieces.map(\.tile)).count, 3)
        // Roughly a 1500 m × 100 m corridor; circles 20 m apart leave slightly scalloped edges.
        let direct = PolygonOps.union(samples.map { model.circle(around: $0.coordinate) })
        XCTAssertEqual(regions[0].areaSquareMeters, direct.areaSquareMeters, accuracy: direct.areaSquareMeters * 0.001)
        XCTAssertEqual(regions[0].areaSquareMeters, 1_500 * 100 + .pi * 2_500, accuracy: 1_500 * 2)
    }

    func testDisconnectedAreasStaySeparateUntilConnected() async throws {
        let store: any MapQuestDataStore = InMemoryDataStore()
        let engine = makeEngine(store: store)
        let west = Walk.line(fromEast: 0, north: 0, toEast: 300, north: 0, step: 20)
        let east = Walk.line(fromEast: 2_000, north: 0, toEast: 2_300, north: 0, step: 20, startSecond: 1_000)
        for sample in west + east { try await engine.process(sample) }

        var regions = try await store.regions(layer: model.layer)
        XCTAssertEqual(regions.count, 2, "phone switched off between the two walks")
        let oldest = regions[0].id
        let westRegion = try await engine.region(at: Walk.coordinate(east: 100, north: 0))
        XCTAssertEqual(westRegion, oldest)

        // Walking from one area to the other connects them.
        let bridge = Walk.line(fromEast: 300, north: 0, toEast: 2_000, north: 0, step: 20, startSecond: 2_000)
        var merged: [UUID] = []
        for sample in bridge {
            merged += try await engine.process(sample).mergedRegionIDs
        }
        regions = try await store.regions(layer: model.layer)
        XCTAssertEqual(regions.map(\.id), [oldest], "the older region absorbs the newer one")
        XCTAssertEqual(merged.count, 1)
        let eastRegion = try await engine.region(at: Walk.coordinate(east: 2_200, north: 0))
        XCTAssertEqual(eastRegion, oldest)
    }

    func testNearlyTouchingAreasAreAdjacent() async throws {
        let store: any MapQuestDataStore = InMemoryDataStore()
        let engine = makeEngine(store: store)
        // Two disks whose edges are 0.5 m apart (< 1 m tolerance) …
        try await engine.process(Walk.sample(east: 0, north: 0, second: 0))
        try await engine.process(Walk.sample(east: 100.5, north: 0, second: 1))
        var regions = try await store.regions(layer: model.layer)
        XCTAssertEqual(regions.count, 1)
        // … but 5 m apart they are separate.
        try await engine.process(Walk.sample(east: 0, north: 105, second: 2))
        regions = try await store.regions(layer: model.layer)
        XCTAssertEqual(regions.count, 2)
    }

    func testTiledAreaEqualsDirectUnion() async throws {
        let store: any MapQuestDataStore = InMemoryDataStore()
        let engine = makeEngine(store: store)
        var generator = SplitMix64(seed: 42)
        var samples: [LocationSample] = []
        var east = 0.0, north = 0.0, heading = 0.0
        for i in 0..<300 {
            heading += Double.random(in: -0.6...0.6, using: &generator)
            east += cos(heading) * 25
            north += sin(heading) * 25
            samples.append(Walk.sample(east: east, north: north, second: Double(i)))
        }
        for sample in samples { try await engine.process(sample) }

        let direct = PolygonOps.union(samples.map { model.circle(around: $0.coordinate) })
        let regions = try await store.regions(layer: model.layer)
        let tiledArea = regions.reduce(0) { $0 + $1.areaSquareMeters }
        XCTAssertEqual(tiledArea, direct.areaSquareMeters, accuracy: direct.areaSquareMeters * 0.002)
        XCTAssertEqual(regions.count, direct.count, "regions = connected components")
    }

    func testRebuildReproducesIncrementalResult() async throws {
        let store: any MapQuestDataStore = InMemoryDataStore()
        let engine = makeEngine(store: store)
        let samples = Walk.line(fromEast: 0, north: 0, toEast: 600, north: 0, step: 15)
            + Walk.line(fromEast: 600, north: 0, toEast: 600, north: 500, step: 15, startSecond: 100)
            + Walk.line(fromEast: 3_000, north: 3_000, toEast: 3_200, north: 3_000, step: 15, startSecond: 500)
        for sample in samples.shuffled() { try await engine.process(sample) }
        let incremental = try await store.regions(layer: model.layer)

        let rebuildStore: any MapQuestDataStore = InMemoryDataStore()
        let rebuilt = makeEngine(store: rebuildStore)
        try await rebuilt.rebuild(from: samples)
        let fromScratch = try await rebuildStore.regions(layer: model.layer)

        XCTAssertEqual(incremental.count, 2)
        XCTAssertEqual(fromScratch.count, incremental.count)
        let a = incremental.map(\.areaSquareMeters).sorted()
        let b = fromScratch.map(\.areaSquareMeters).sorted()
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: x * 0.002) }
        // Rebuilt regions carry the true first-discovery times (chronological replay).
        XCTAssertEqual(fromScratch.map(\.firstDiscovered).min(), samples.map(\.timestamp).min())
    }

    func testEngineReloadsFromStore() async throws {
        let store: any MapQuestDataStore = InMemoryDataStore()
        let engine = makeEngine(store: store)
        for sample in Walk.line(fromEast: 0, north: 0, toEast: 400, north: 0, step: 20) {
            try await engine.process(sample)
        }
        let fresh = makeEngine(store: store)
        let known = try await fresh.evaluate(Walk.sample(east: 200, north: 0, second: 999))
        XCTAssertEqual(known.newAreaSquareMeters, 0, accuracy: 1)
        try await fresh.loadAll()
        let snapshot = await fresh.snapshot()
        let original = await engine.snapshot()
        XCTAssertEqual(snapshot.totalAreaSquareMeters, original.totalAreaSquareMeters, accuracy: 1e-6)
        XCTAssertEqual(snapshot.regions.count, 1)
        XCTAssertTrue(snapshot.isDiscovered(WebMercator.project(Walk.coordinate(east: 100, north: 10))))
        XCTAssertFalse(snapshot.isDiscovered(WebMercator.project(Walk.coordinate(east: 100, north: 80))))
        let rect = WebMercator.worldRect(for: GeoBoundingBox(center: Walk.coordinate(east: 100, north: 0), radius: 30))
        XCTAssertFalse(snapshot.pieces(intersecting: rect).isEmpty)
    }

    func testPiecesStayCompact() async throws {
        let engine = makeEngine()
        var generator = SplitMix64(seed: 7)
        var east = 0.0, north = 0.0
        for i in 0..<400 {
            east += Double.random(in: -30...30, using: &generator)
            north += Double.random(in: -30...30, using: &generator)
            try await engine.process(Walk.sample(east: east, north: north, second: Double(i)))
        }
        let snapshot = await engine.snapshot()
        let maxVertices = snapshot.piecesByTile.values.flatMap { $0 }.map(\.polygon.vertexCount).max() ?? 0
        XCTAssertLessThan(maxVertices, 2_000, "tiling keeps every union bounded")
    }
}

final class LocationRecorderTests: XCTestCase {
    func testRecordsOnlyFixesThatRevealNewArea() async throws {
        let store: any MapQuestDataStore = InMemoryDataStore()
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(radius: 50), store: store)
        let recorder = LocationRecorder(store: store, engines: [engine])

        var outcome = try await recorder.record(Walk.sample(east: 0, north: 0, second: 0))
        XCTAssertTrue(outcome.isRecorded)
        // Standing still: nothing new.
        outcome = try await recorder.record(Walk.sample(east: 1, north: 1, second: 1))
        guard case .alreadyDiscovered = outcome else { return XCTFail("expected already discovered, got \(outcome)") }
        // Walking 1 m per second along a street: fixes are evaluated every 5 m and
        // stored about every 10 m (when ≥ 10 % of the disk is new).
        for i in 1...100 {
            _ = try await recorder.record(Walk.sample(east: Double(i), north: 0, second: Double(10 + i)))
        }
        let count = try await store.sampleCount()
        XCTAssertGreaterThanOrEqual(count, 8)
        XCTAssertLessThanOrEqual(count, 16)
        // Walking back along the same street stores nothing.
        for i in stride(from: 100, through: 0, by: -1) {
            _ = try await recorder.record(Walk.sample(east: Double(i), north: 0, second: Double(200 + i)))
        }
        let countAfterReturn = try await store.sampleCount()
        XCTAssertEqual(countAfterReturn, count)
    }

    func testRejectsInvalidInaccurateAndOutsideFixes() async throws {
        let store: any MapQuestDataStore = InMemoryDataStore()
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(radius: 50), store: store)
        let square = WorldPolygon(exterior: WebMercator.worldRect(
            for: GeoBoundingBox(center: Walk.origin, radius: 1_000)
        ).corners)
        let recorder = LocationRecorder(store: store, engines: [engine], playArea: PlayArea(name: "Test", polygons: [square]))

        var outcome = try await recorder.record(Walk.sample(east: 0, north: 0, second: 0, accuracy: -1))
        guard case .rejected(.invalidPosition) = outcome else { return XCTFail("\(outcome)") }
        outcome = try await recorder.record(Walk.sample(east: 0, north: 0, second: 0, accuracy: 120))
        guard case .rejected(.inaccurate) = outcome else { return XCTFail("\(outcome)") }
        outcome = try await recorder.record(Walk.sample(east: 5_000, north: 0, second: 0))
        guard case .rejected(.outsidePlayArea) = outcome else { return XCTFail("\(outcome)") }
        let count = try await store.sampleCount()
        XCTAssertEqual(count, 0)
    }

    func testRebuildAllLayersFromStoredSamples() async throws {
        let store: any MapQuestDataStore = InMemoryDataStore()
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(radius: 50), store: store)
        let recorder = LocationRecorder(store: store, engines: [engine])
        for sample in Walk.line(fromEast: 0, north: 0, toEast: 500, north: 0, step: 5) {
            _ = try await recorder.record(sample)
        }
        let before = try await store.regions(layer: engine.layer)
        try await store.removeAllPieces(layer: engine.layer)
        await engine.invalidateCache()
        try await recorder.rebuildAllLayers()
        let after = try await store.regions(layer: engine.layer)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].areaSquareMeters, before[0].areaSquareMeters, accuracy: 1)
    }
}

/// Deterministic random numbers for reproducible tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A discovery model that fails, like the 3D model without building data.
struct FailingModel: DiscoveryModel {
    var layer: DiscoveryLayerID { "failing" }
    func revealedArea(for sample: LocationSample) async throws -> [WorldPolygon] {
        throw BuildingSourceError.unavailable("offline")
    }
}

final class RecorderResilienceTests: XCTestCase {
    func testFailingLayerDoesNotStopRecordingAndBecomesStale() async throws {
        let store = InMemoryDataStore()
        let circle = DiscoveryEngine(model: CircleDiscoveryModel(radius: 50), store: store)
        let failing = DiscoveryEngine(model: FailingModel(), store: store)
        let recorder = LocationRecorder(store: store, engines: [circle, failing])
        let outcome = try await recorder.record(Walk.sample(east: 0, north: 0, second: 0))
        XCTAssertTrue(outcome.isRecorded)
        let stale = await recorder.staleLayers
        XCTAssertEqual(stale, ["failing"])
        let errors = await recorder.lastErrors
        XCTAssertNotNil(errors["failing"])

        // A failed rebuild leaves the stored layer untouched.
        do {
            try await failing.rebuild(from: [Walk.sample(east: 0, north: 0, second: 0)])
            XCTFail("expected an error")
        } catch {}
        let circleRegions = try await store.regions(layer: circle.layer)
        XCTAssertEqual(circleRegions.count, 1)
    }

    func testAllLayersFailingThrows() async {
        let store = InMemoryDataStore()
        let recorder = LocationRecorder(store: store, engines: [DiscoveryEngine(model: FailingModel(), store: store)])
        do {
            _ = try await recorder.record(Walk.sample(east: 0, north: 0, second: 0))
            XCTFail("expected an error")
        } catch {}
    }
}

/// Counts how often it is asked for revealed area.
final class CountingModel: DiscoveryModel, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var evaluations: Int { lock.lock(); defer { lock.unlock() }; return count }
    var layer: DiscoveryLayerID { "counting" }
    func revealedArea(for sample: LocationSample) -> [WorldPolygon] {
        lock.lock(); count += 1; lock.unlock()
        return CircleDiscoveryModel(radius: 50).revealedArea(for: sample)
    }
}

final class RecorderThrottleTests: XCTestCase {
    func testFixesCloseToTheLastEvaluatedOneAreNotEvaluated() async throws {
        let store = InMemoryDataStore()
        let model = CountingModel()
        let recorder = LocationRecorder(store: store, engines: [DiscoveryEngine(model: model, store: store)])
        _ = try await recorder.record(Walk.sample(east: 0, north: 0, second: 0))
        // Standing still with GPS jitter.
        for i in 1...10 {
            _ = try await recorder.record(Walk.sample(east: Double(i % 3), north: Double(i % 2), second: Double(i)))
        }
        XCTAssertEqual(model.evaluations, 1, "committing reuses the evaluation")
        // Climbing (e.g. a tower) triggers a new evaluation even without horizontal movement.
        var high = Walk.sample(east: 0, north: 0, second: 20)
        high.altitude += 30
        _ = try await recorder.record(high)
        XCTAssertEqual(model.evaluations, 2)
        // Moving on triggers evaluations again.
        _ = try await recorder.record(Walk.sample(east: 30, north: 0, second: 30))
        XCTAssertEqual(model.evaluations, 3)
    }
}

