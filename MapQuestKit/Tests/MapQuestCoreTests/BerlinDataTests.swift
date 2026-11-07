import XCTest
@testable import MapQuestCore

/// Checks the bundled Berlin play-area data (App/MapQuest/Resources/Berlin).
final class BerlinDataTests: XCTestCase {
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/MapQuest/Resources/Berlin")

    func load(_ name: String) throws -> Data {
        try Data(contentsOf: Self.resources.appendingPathComponent(name))
    }

    func testBoundary() throws {
        let berlin = try GeoJSON.playArea(named: "Berlin", from: load("berlin-boundary.geojson"))
        XCTAssertEqual(berlin.areaSquareMeters / 1e6, 891, accuracy: 6, "Berlin is 891 km²")
        XCTAssertTrue(berlin.contains(GeoCoordinate(latitude: 52.521918, longitude: 13.413215)), "Alexanderplatz")
        XCTAssertTrue(berlin.contains(GeoCoordinate(latitude: 52.4380, longitude: 13.6590)), "Müggelsee shore")
        XCTAssertFalse(berlin.contains(GeoCoordinate(latitude: 52.3906, longitude: 13.0645)), "Potsdam")
        XCTAssertFalse(berlin.contains(GeoCoordinate(latitude: 53.5511, longitude: 9.9937)), "Hamburg")
    }

    func testDistricts() throws {
        let features = try GeoJSON.polygonFeatures(from: load("berlin-districts.geojson"))
        XCTAssertEqual(features.count, 12)
        let names = Set(features.compactMap { $0.properties["name"] })
        XCTAssertTrue(names.isSuperset(of: ["Mitte", "Pankow", "Neukölln", "Treptow-Köpenick"]))
        let total = features.reduce(0) { $0 + $1.polygons.areaSquareMeters }
        XCTAssertEqual(total / 1e6, 891, accuracy: 6)
        let mitte = try XCTUnwrap(features.first { $0.properties["name"] == "Mitte" })
        let area = PlayArea(name: "Mitte", polygons: mitte.polygons)
        XCTAssertTrue(area.contains(GeoCoordinate(latitude: 52.516275, longitude: 13.377704)), "Brandenburger Tor is in Mitte")
    }

    func testDemoWalksFormThreeRegions() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixes = try decoder.decode([LocationSample].self, from: load("demo-walks.json"))
        XCTAssertGreaterThan(fixes.count, 1_000)

        let store = InMemoryDataStore()
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(radius: 50), store: store)
        let berlin = try GeoJSON.playArea(named: "Berlin", from: load("berlin-boundary.geojson"))
        let recorder = LocationRecorder(store: store, engines: [engine], playArea: berlin)
        for fix in fixes { _ = try await recorder.record(fix) }

        let stored = await store.sampleCount()
        XCTAssertLessThan(stored, fixes.count / 2, "only fixes revealing new area are stored")
        let regions = try await store.regions(layer: engine.layer)
        // Mitte walks (connected at Brandenburger Tor and Friedrichstraße), Tempelhofer Feld, Bergmannstraße.
        XCTAssertEqual(regions.count, 3)
    }
}
