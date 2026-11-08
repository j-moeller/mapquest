import XCTest
@testable import MapQuestCore

/// Checks the bundled Braunschweig data (App/MapQuest/Resources/Braunschweig,
/// built by .github/workflows/braunschweig-data.yml) and recording in two cities.
final class BraunschweigDataTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/MapQuest/Resources")

    func load(_ city: String, _ name: String) throws -> Data {
        try Data(contentsOf: Self.root.appendingPathComponent(city).appendingPathComponent(name))
    }

    let burgplatz = GeoCoordinate(latitude: 52.2642, longitude: 10.5236)

    func braunschweig() throws -> PlayArea {
        var city = try GeoJSON.playArea(named: "Braunschweig", from: load("Braunschweig", "braunschweig-boundary.geojson"))
        city.subdivisions = try GeoJSON.polygonFeatures(from: load("Braunschweig", "braunschweig-districts.geojson"))
            .map { PlayArea(name: $0.properties["name"] ?? "?", polygons: $0.polygons) }
        return city
    }

    func testOutlineAndDistricts() throws {
        let city = try braunschweig()
        XCTAssertEqual(city.areaSquareMeters / 1e6, 192.5, accuracy: 3, "Braunschweig covers ≈ 192 km²")
        XCTAssertTrue(city.contains(burgplatz))
        XCTAssertFalse(city.contains(GeoCoordinate(latitude: 52.1620, longitude: 10.5350)), "Wolfenbüttel is a separate town")
        XCTAssertEqual(city.subdivisions.count, 12, "the Stadtbezirke")
        let names = Set(city.subdivisions.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["Mitte", "Weststadt", "Östliches Ringgebiet"]))
        let sum = city.subdivisions.reduce(0) { $0 + $1.areaSquareMeters }
        XCTAssertEqual(sum, city.areaSquareMeters, accuracy: city.areaSquareMeters * 0.01, "the districts tile the city")
        XCTAssertEqual(city.subdivisions.first { $0.contains(burgplatz) }?.name, "Mitte")
    }

    func testTerrain() throws {
        let terrain = try GridTerrain(identifier: "braunschweig-dgm30", data: load("Braunschweig", "braunschweig-terrain.dem"), fallback: 75)
        XCTAssertTrue(terrain.covers(latitude: burgplatz.latitude, longitude: burgplatz.longitude))
        XCTAssertEqual(terrain.elevation(latitude: burgplatz.latitude, longitude: burgplatz.longitude), 73, accuracy: 8, "Burgplatz, Oker valley")
        XCTAssertFalse(terrain.covers(latitude: 52.52, longitude: 13.40), "Berlin is not in this grid")
        let berlin = try GridTerrain(identifier: "berlin-dgm30", data: load("Berlin", "berlin-terrain.dem"), fallback: 35)
        let both = CompositeTerrain([berlin, terrain], fallback: 35)
        XCTAssertEqual(both.elevation(at: WebMercator.project(GeoCoordinate(latitude: 52.5219, longitude: 13.4132))), 37, accuracy: 4)
        XCTAssertEqual(both.elevation(at: WebMercator.project(burgplatz)), terrain.elevation(latitude: burgplatz.latitude, longitude: burgplatz.longitude), accuracy: 0.01)
    }

    func testTheDemoDayTripIsRecordedInBraunschweig() async throws {
        let berlin = try GeoJSON.playArea(named: "Berlin", from: load("Berlin", "berlin-boundary.geojson"))
        let city = try braunschweig()
        let both = PlayArea(name: "Berlin & Braunschweig", polygons: berlin.polygons + city.polygons, subdivisions: [berlin, city])
        let points = try TrackCodec.decode(load("Berlin", "demo-track.mqtrack"))
        let trip = points.filter { city.contains($0.coordinate) }
        XCTAssertGreaterThan(trip.count, 1_000)
        let store = InMemoryDataStore()
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(), store: store)
        let recorder = LocationRecorder(store: store, engines: [engine], playArea: both)
        for point in trip { _ = try await recorder.record(point.sample) }
        try await recorder.finishSampling()
        let coverage = DiscoveryStatistics.coverage(of: await engine.snapshot(), in: [city])
        XCTAssertGreaterThan(coverage[0].discoveredSquareMeters, 100_000, "≈ 4 km walked with a 50 m radius")
    }
}
