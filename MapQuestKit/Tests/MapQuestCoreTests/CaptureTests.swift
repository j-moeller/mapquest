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
        XCTAssertEqual(sight.captureTolerance, 0, "small sights must be covered")
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        // Discovered area ending 10 m before the sight: not captured (it must be covered).
        let near = piece(around: east(sight.coordinate, 30), half: 20, discovered: early)
        XCTAssertNil(SightCapture.captureDate(of: sight, in: [snapshot([near])]))
        // Covering it: captured; the earliest covering piece gives the date.
        let on = piece(around: east(sight.coordinate, 15), half: 20, discovered: late)
        let onEarlier = piece(around: sight.coordinate, half: 10, discovered: early)
        XCTAssertEqual(SightCapture.captureDate(of: sight, in: [snapshot([near, on])]), late)
        XCTAssertEqual(SightCapture.captureDate(of: sight, in: [snapshot([on]), snapshot([onEarlier])]), early)
        XCTAssertNil(SightCapture.captureDate(of: sight, in: [snapshot([])]))

        // A large open area (150 m): reached within 100 m of its position.
        let field = Sight(id: "f", name: "F", category: .park, latitude: 52.4733, longitude: 13.4019, radius: 150)
        XCTAssertEqual(field.captureTolerance, 100)
        let inside = piece(around: east(field.coordinate, 100), half: 20, discovered: late)  // edge at 80 m
        XCTAssertEqual(SightCapture.captureDate(of: field, in: [snapshot([inside])]), late)
        let outside = piece(around: east(field.coordinate, 140), half: 20, discovered: late)  // edge at 120 m
        XCTAssertNil(SightCapture.captureDate(of: field, in: [snapshot([outside])]))
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

        // Logs made under the first (looser) rule are discarded once.
        var old = log
        old.version = 1
        try store.save(old)
        XCTAssertEqual(try store.load(), CaptureLog())
        XCTAssertEqual(CaptureLog().version, CaptureLog.currentVersion)
    }

    /// End to end with the radius layer (50 m circles): a position at the
    /// Brandenburger Tor captures it; one 80 m east of it does not (the circle
    /// ends 30 m before the gate); the Reichstag 250 m away is never captured.
    func testAPositionCapturesTheSightThere() async throws {
        let catalog = try Self.berlinSights()
        let gate = try XCTUnwrap(catalog["brandenburger-tor"])

        func captures(at coordinate: GeoCoordinate) async throws -> CaptureLog {
            let store = InMemoryDataStore()
            let engine = DiscoveryEngine(model: CircleDiscoveryModel(), store: store)
            let recorder = LocationRecorder(store: store, engines: [engine])
            let sample = LocationSample(
                latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 36,
                horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
            )
            _ = try await recorder.record(sample)
            try await recorder.finishSampling()
            var log = CaptureLog()
            SightCapture.update(&log, sights: catalog.sights, snapshots: [await engine.snapshot()])
            return log
        }

        let there = try await captures(at: gate.coordinate)
        XCTAssertTrue(there.isCaptured("brandenburger-tor"))
        XCTAssertFalse(there.isCaptured("reichstag"))
        XCTAssertFalse(there.isCaptured("fernsehturm"))
        let nearby = try await captures(at: east(gate.coordinate, 80))
        XCTAssertFalse(nearby.isCaptured("brandenburger-tor"))
    }
}
