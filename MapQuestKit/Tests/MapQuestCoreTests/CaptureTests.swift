import XCTest
@testable import MapQuestCore

final class CaptureTests: XCTestCase {
    static func berlinSights() throws -> SightCatalog {
        try SightCatalog.decode(Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Berlin/berlin-sights.json")))
    }

    /// A square piece of discovered area, `half` metres from its centre to each side.
    func piece(around coordinate: GeoCoordinate, half: Double, discovered: Date) -> DiscoveredPiece {
        let center = WebMercator.project(coordinate)
        let h = Int64(half / WebMercator.metersPerUnit(atWorldY: Double(center.y)))
        let polygon = WorldPolygon(exterior: [
            WorldPoint(x: center.x - h, y: center.y - h), WorldPoint(x: center.x + h, y: center.y - h),
            WorldPoint(x: center.x + h, y: center.y + h), WorldPoint(x: center.x - h, y: center.y + h),
        ])
        return DiscoveredPiece(
            layer: "test", regionID: UUID(), tile: TileKey(containing: center, zoom: DiscoveryGrid.zoom),
            polygon: polygon, areaSquareMeters: 4 * half * half, firstDiscovered: discovered, lastUpdated: discovered
        )
    }

    func snapshot(_ pieces: [DiscoveredPiece]) -> DiscoveredAreaSnapshot {
        DiscoveredAreaSnapshot(layer: "test", piecesByTile: Dictionary(grouping: pieces, by: \.tile), maximumMarginUnits: 0)
    }

    /// Moves a coordinate east by `meters`.
    func east(_ c: GeoCoordinate, _ meters: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: c.latitude, longitude: c.longitude + meters / (111_320 * cos(c.latitude * .pi / 180)))
    }

    func testBundledBerlinSights() throws {
        let catalog = try Self.berlinSights()
        XCTAssertEqual(catalog.count, 119)
        let berlin = try GeoJSON.playArea(named: "Berlin", from: Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Berlin/berlin-boundary.geojson")))
        for sight in catalog.sights {
            XCTAssertTrue(berlin.contains(sight.coordinate), "\(sight.name) lies in Berlin")
            XCTAssertTrue((30...150).contains(sight.radius), sight.name)
            XCTAssertFalse(sight.name.isEmpty)
        }
        let gate = try XCTUnwrap(catalog["brandenburger-tor"])
        XCTAssertEqual(gate.category, .monument)
        XCTAssertEqual(gate.latitude, 52.5163, accuracy: 0.001)
        XCTAssertEqual(gate.longitude, 13.3777, accuracy: 0.001)
        XCTAssertEqual(Set(catalog.sights.map(\.category)).count, SightCategory.allCases.count, "every category is used")
    }

    func testCaptureRule() throws {
        let sight = Sight(id: "s", name: "S", category: .monument, latitude: 52.5163, longitude: 13.3777, radius: 40)
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        // Discovered area 30 m away (edge), within the radius.
        let near = piece(around: east(sight.coordinate, 50), half: 20, discovered: late)
        XCTAssertEqual(SightCapture.captureDate(of: sight, in: [snapshot([near])]), late)
        // 70 m away (edge at 60 m): not reached.
        let far = piece(around: east(sight.coordinate, 80), half: 20, discovered: early)
        XCTAssertNil(SightCapture.captureDate(of: sight, in: [snapshot([far])]))
        // On the sight, in another layer, discovered earlier: the earliest wins.
        let on = piece(around: sight.coordinate, half: 10, discovered: early)
        XCTAssertEqual(SightCapture.captureDate(of: sight, in: [snapshot([near]), snapshot([on])]), early)
        XCTAssertNil(SightCapture.captureDate(of: sight, in: [snapshot([])]))
    }

    func testLogUpdateCelebrationAndStore() throws {
        let sights = [
            Sight(id: "a", name: "A", category: .museum, latitude: 52.52, longitude: 13.40),
            Sight(id: "b", name: "B", category: .church, latitude: 52.53, longitude: 13.41),
        ]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let area = snapshot([piece(around: sights[0].coordinate, half: 30, discovered: date)])
        var log = CaptureLog()
        let added = SightCapture.update(&log, sights: sights, snapshots: [area], now: date)
        XCTAssertEqual(added.map(\.sightID), ["a"])
        XCTAssertEqual(log.uncelebrated.map(\.sightID), ["a"])
        XCTAssertTrue(SightCapture.update(&log, sights: sights, snapshots: [area]).isEmpty, "captured once")
        log.markCelebrated(["a"])
        XCTAssertTrue(log.uncelebrated.isEmpty)

        // View-only sources: recorded as celebrated.
        var other = CaptureLog()
        SightCapture.update(&other, sights: sights, snapshots: [area], celebrate: false)
        XCTAssertTrue(other.uncelebrated.isEmpty)
        XCTAssertTrue(other.isCaptured("a"))

        // Captures stay when the area shrinks (another rebuild).
        SightCapture.update(&log, sights: sights, snapshots: [snapshot([])])
        XCTAssertTrue(log.isCaptured("a"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("captures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCaptureStore(directory: directory, sourceID: "local/own profile")
        XCTAssertEqual(store.url.lastPathComponent, "local_own_profile.json")
        XCTAssertEqual(try store.load(), CaptureLog(), "empty without a file")
        try store.save(log)
        XCTAssertEqual(try store.load(), log)
        try store.delete()
        XCTAssertEqual(try store.load(), CaptureLog())
    }

    /// End to end: one position at the Brandenburger Tor captures it (and its
    /// neighbour the Reichstag is 250 m away: not captured by the 50 m circle).
    func testAPositionCapturesTheSightThere() async throws {
        let catalog = try Self.berlinSights()
        let gate = try XCTUnwrap(catalog["brandenburger-tor"])
        let store = InMemoryDataStore()
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(), store: store)
        let recorder = LocationRecorder(store: store, engines: [engine])
        let sample = LocationSample(
            latitude: gate.latitude, longitude: gate.longitude, altitude: 36,
            horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
        )
        _ = try await recorder.record(sample)
        try await recorder.finishSampling()
        var log = CaptureLog()
        let added = SightCapture.update(&log, sights: catalog.sights, snapshots: [await engine.snapshot()])
        XCTAssertTrue(added.contains { $0.sightID == "brandenburger-tor" })
        XCTAssertFalse(log.isCaptured("reichstag"))
        XCTAssertFalse(log.isCaptured("fernsehturm"))
    }
}
