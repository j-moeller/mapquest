import XCTest
@testable import MapQuestCore

/// Checks the bundled Peine data (App/MapQuest/Resources/Peine, built by
/// Tools/cities/build_city.sh from BKG VG250 and LGLN LoD2/DGM1, docs/07-peine-data.md).
final class PeineDataTests: XCTestCase {
    let marktplatz = GeoCoordinate(latitude: 52.3203, longitude: 10.2337)

    func load(_ city: String, _ name: String) throws -> Data {
        try Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent(city).appendingPathComponent(name))
    }

    func testOutline() throws {
        let peine = try GeoJSON.playArea(named: "Peine", from: load("Peine", "peine-boundary.geojson"))
        XCTAssertEqual(peine.areaSquareMeters / 1e6, 119.5, accuracy: 2, "Peine covers ≈ 119.5 km²")
        XCTAssertTrue(peine.contains(marktplatz))
        XCTAssertTrue(peine.contains(GeoCoordinate(latitude: 52.3360, longitude: 10.2020)), "Vöhrum is part of Peine")
        XCTAssertFalse(peine.contains(GeoCoordinate(latitude: 52.2642, longitude: 10.5236)), "Braunschweig is not")
        XCTAssertFalse(peine.contains(GeoCoordinate(latitude: 52.2660, longitude: 10.2200)), "nor Ilsede")
        let districts = BraunschweigDataTests.root.appendingPathComponent("Peine/peine-districts.geojson")
        XCTAssertFalse(FileManager.default.fileExists(atPath: districts.path), "no districts bundled (VG250 has none)")
    }

    func testTerrain() throws {
        let terrain = try GridTerrain(identifier: "peine-dgm30", data: load("Peine", "peine-terrain.dem"), fallback: 67)
        XCTAssertTrue(terrain.covers(latitude: marktplatz.latitude, longitude: marktplatz.longitude))
        XCTAssertEqual(terrain.elevation(latitude: marktplatz.latitude, longitude: marktplatz.longitude), 67, accuracy: 8, "old town, Fuhse valley")
        XCTAssertFalse(terrain.covers(latitude: 52.2642, longitude: 10.5236), "Braunschweig is not in this grid")
    }

    func testThreeCitiesTogether() throws {
        let cities = try [("Berlin", "berlin"), ("Braunschweig", "braunschweig"), ("Peine", "peine")].map { name, id in
            try GeoJSON.playArea(named: name, from: load(name, "\(id)-boundary.geojson"))
        }
        let both = try CompositeTerrain([
            GridTerrain(identifier: "braunschweig-dgm30", data: load("Braunschweig", "braunschweig-terrain.dem"), fallback: 75),
            GridTerrain(identifier: "peine-dgm30", data: load("Peine", "peine-terrain.dem"), fallback: 67),
        ], fallback: 35)
        XCTAssertEqual(cities.filter { $0.contains(marktplatz) }.map(\.name), ["Peine"])
        XCTAssertEqual(both.identifier, "braunschweig-dgm30+peine-dgm30")
        XCTAssertEqual(both.elevation(at: WebMercator.project(GeoCoordinate(latitude: 52.40, longitude: 11.00))), 35, "no grid: fallback")
    }
}
