import XCTest
@testable import MapQuestCore

final class LabelPlacementTests: XCTestCase {
    func testLabelPointOfAConcaveShapeLiesInside() {
        // A U shape whose centroid (the middle of the gap) is outside.
        let u = WorldPolygon(exterior: [
            WorldPoint(x: 0, y: 0), WorldPoint(x: 300, y: 0), WorldPoint(x: 300, y: 300), WorldPoint(x: 200, y: 300),
            WorldPoint(x: 200, y: 100), WorldPoint(x: 100, y: 100), WorldPoint(x: 100, y: 300), WorldPoint(x: 0, y: 300),
        ])
        XCTAssertFalse(u.contains(WorldPoint(x: 150, y: 200)), "the gap")
        let point = u.labelPoint()
        XCTAssertTrue(u.contains(point))
        XCTAssertGreaterThan(u.distanceToBoundary(point), 30)
    }

    func testDistanceToBoundary() {
        let square = WorldPolygon(exterior: [WorldPoint(x: 0, y: 0), WorldPoint(x: 100, y: 0), WorldPoint(x: 100, y: 100), WorldPoint(x: 0, y: 100)])
        XCTAssertEqual(square.distanceToBoundary(WorldPoint(x: 50, y: 50)), 50, accuracy: 1e-9)
        XCTAssertEqual(square.distanceToBoundary(WorldPoint(x: 10, y: 50)), 10, accuracy: 1e-9)
        XCTAssertEqual(square.distanceToBoundary(WorldPoint(x: 150, y: 100)), 50, accuracy: 1e-9)
    }

    func testBundledCitiesAndDistrictsGetLabelsInside() throws {
        let root = BraunschweigDataTests.root
        func load(_ city: String, _ file: String) throws -> Data {
            try Data(contentsOf: root.appendingPathComponent(city).appendingPathComponent(file))
        }
        var areas: [PlayArea] = []
        for (name, id, hasDistricts) in [("Berlin", "berlin", true), ("Braunschweig", "braunschweig", true), ("Peine", "peine", false)] {
            areas.append(try GeoJSON.playArea(named: name, from: load(name, "\(id)-boundary.geojson")))
            if hasDistricts {
                areas += try GeoJSON.polygonFeatures(from: load(name, "\(id)-districts.geojson"))
                    .map { PlayArea(name: $0.properties["name"] ?? "?", polygons: $0.polygons) }
            }
        }
        XCTAssertEqual(areas.count, 3 + 12 + 12)
        for area in areas {
            let point = try XCTUnwrap(area.labelPoint, area.name)
            XCTAssertTrue(area.polygons.contains { $0.contains(point) }, "\(area.name): label inside")
            let polygon = try XCTUnwrap(area.polygons.max { $0.area < $1.area })
            let meters = polygon.distanceToBoundary(point) * WebMercator.metersPerUnit(atWorldY: Double(point.y))
            XCTAssertGreaterThan(meters, 400, "\(area.name): label well inside")
        }
    }
}
