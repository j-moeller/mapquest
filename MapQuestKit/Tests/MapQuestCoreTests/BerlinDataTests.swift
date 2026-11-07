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

    func testTerrainModel() throws {
        let terrain = try GridTerrain(identifier: "berlin-dgm30", data: load("berlin-terrain.dem"), fallback: 35)
        func elevation(_ lat: Double, _ lon: Double) -> Double { terrain.elevation(latitude: lat, longitude: lon) }
        XCTAssertEqual(elevation(52.5219, 13.4132), 37, accuracy: 4, "Alexanderplatz (Spree valley)")
        XCTAssertEqual(elevation(52.4975, 13.2414), 115, accuracy: 8, "Teufelsberg summit")
        XCTAssertEqual(elevation(52.4874, 13.3812), 63, accuracy: 6, "Kreuzberg (Viktoriapark)")
        XCTAssertGreaterThan(elevation(52.5363, 13.4174), 45, "Prenzlauer Berg lies on the Barnim plateau")
        XCTAssertEqual(elevation(52.3906, 13.0645), 35, "outside Berlin: fallback")

        // On the Barnim plateau a street-level fix no longer counts as elevated.
        let model = ViewshedDiscoveryModel(buildings: InMemoryBuildingSource([]), terrain: terrain)
        let ground = elevation(52.5363, 13.4174)
        let street = LocationSample(latitude: 52.5363, longitude: 13.4174, altitude: ground + 2, verticalAccuracy: 4, timestamp: Date())
        XCTAssertEqual(model.heights(for: street).eye, 1.7, accuracy: 1e-9)
        let flat = ViewshedDiscoveryModel(buildings: InMemoryBuildingSource([]))
        XCTAssertGreaterThan(flat.heights(for: street).eye, 5, "with flat terrain it looked like a high point")

        // Teufelsberg: street level, but far above the surroundings.
        let summit = LocationSample(latitude: 52.4975, longitude: 13.2414, altitude: elevation(52.4975, 13.2414) + 2, verticalAccuracy: 4, timestamp: Date())
        let heights = model.heights(for: summit)
        XCTAssertEqual(heights.eye, 1.7, accuracy: 1e-9)
        XCTAssertGreaterThan(heights.effective, 25)
    }
}

