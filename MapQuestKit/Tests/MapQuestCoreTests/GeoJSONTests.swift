import XCTest
@testable import MapQuestCore

final class GeoJSONTests: XCTestCase {
    /// A 1 km × 1 km square near Alexanderplatz with a 200 m hole, as GeoJSON.
    func squareGeoJSON(name: String = "Square") -> Data {
        let a = Walk.coordinate(east: 0, north: 0), b = Walk.coordinate(east: 1_000, north: 1_000)
        let h1 = Walk.coordinate(east: 400, north: 400), h2 = Walk.coordinate(east: 600, north: 600)
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"name":"\(name)","code":7},
           "geometry":{"type":"Polygon","coordinates":[
             [[\(a.longitude),\(a.latitude)],[\(b.longitude),\(a.latitude)],[\(b.longitude),\(b.latitude)],[\(a.longitude),\(b.latitude)],[\(a.longitude),\(a.latitude)]],
             [[\(h1.longitude),\(h1.latitude)],[\(h1.longitude),\(h2.latitude)],[\(h2.longitude),\(h2.latitude)],[\(h2.longitude),\(h1.latitude)],[\(h1.longitude),\(h1.latitude)]]
           ]}},
          {"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[13.4,52.5]}}
        ]}
        """
        return Data(json.utf8)
    }

    func testReadsPolygonFeatures() throws {
        let features = try GeoJSON.polygonFeatures(from: squareGeoJSON())
        XCTAssertEqual(features.count, 1, "points are skipped")
        XCTAssertEqual(features[0].properties, ["name": "Square", "code": "7"])
        let polygon = features[0].polygons[0]
        XCTAssertEqual(polygon.exterior.count, 4, "closing position removed")
        XCTAssertEqual(polygon.holes.count, 1)
        XCTAssertEqual(polygon.areaSquareMeters, 1_000_000 - 40_000, accuracy: 2_000)
    }

    func testPlayAreaContainment() throws {
        let area = try GeoJSON.playArea(named: "Square", from: squareGeoJSON())
        XCTAssertTrue(area.contains(Walk.coordinate(east: 100, north: 100)))
        XCTAssertFalse(area.contains(Walk.coordinate(east: 500, north: 500)), "inside the hole")
        XCTAssertFalse(area.contains(Walk.coordinate(east: 1_500, north: 100)))
        XCTAssertTrue(PlayArea.world.contains(GeoCoordinate(latitude: -33.9, longitude: 151.2)))
    }

    func testRejectsMalformedInput() {
        XCTAssertThrowsError(try GeoJSON.polygonFeatures(from: Data("[1,2]".utf8)))
        XCTAssertThrowsError(try GeoJSON.polygonFeatures(from: Data(#"{"type":"Polygon","coordinates":[[[1,2]]]}"#.utf8)))
        XCTAssertThrowsError(try GeoJSON.polygonFeatures(from: Data(#"{"type":"Banana"}"#.utf8)))
    }

    func testExportRoundTripsDiscoveredArea() async throws {
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(radius: 50), store: InMemoryDataStore())
        for sample in Walk.line(fromEast: 0, north: 0, toEast: 600, north: 0, step: 20) {
            try await engine.process(sample)
        }
        let pieces = await engine.snapshot().piecesByTile.values.flatMap { $0 }
        let data = GeoJSON.featureCollection(pieces: pieces)
        let features = try GeoJSON.polygonFeatures(from: data)
        XCTAssertEqual(features.count, pieces.count)
        XCTAssertEqual(Set(features.compactMap { $0.properties["layer"] }), ["circle-50m"])
        let reimported = PolygonOps.union(features.flatMap(\.polygons)).areaSquareMeters
        let original = PolygonOps.union(pieces.map(\.polygon)).areaSquareMeters
        XCTAssertEqual(reimported, original, accuracy: original * 0.001)

        // RFC 7946 orientation: exterior rings are counter-clockwise in lon/lat.
        let exterior = GeoJSON.coordinates(of: pieces[0].polygon)[0]
        var sum = 0.0
        for i in 0..<(exterior.count - 1) {
            sum += exterior[i][0] * exterior[i + 1][1] - exterior[i + 1][0] * exterior[i][1]
        }
        XCTAssertGreaterThan(sum, 0)
    }

    func testExportsSamples() throws {
        let samples = [Walk.sample(east: 0, north: 0, second: 0)]
        let object = try JSONSerialization.jsonObject(with: GeoJSON.featureCollection(samples: samples)) as? [String: Any]
        let features = object?["features"] as? [[String: Any]]
        let geometry = features?.first?["geometry"] as? [String: Any]
        let coordinates = geometry?["coordinates"] as? [Double]
        XCTAssertEqual(coordinates?.count, 3)
        XCTAssertEqual(coordinates?[2], 40)
    }

    func testDistrictCoverage() async throws {
        let west = PlayArea(name: "West", polygons: [WorldPolygon(exterior: WebMercator.worldRect(for: GeoBoundingBox(
            minLatitude: Walk.origin.latitude - 0.01, minLongitude: Walk.origin.longitude - 0.02,
            maxLatitude: Walk.origin.latitude + 0.01, maxLongitude: Walk.origin.longitude
        )).corners)])
        let east = PlayArea(name: "East", polygons: [WorldPolygon(exterior: WebMercator.worldRect(for: GeoBoundingBox(
            minLatitude: Walk.origin.latitude - 0.01, minLongitude: Walk.origin.longitude,
            maxLatitude: Walk.origin.latitude + 0.01, maxLongitude: Walk.origin.longitude + 0.02
        )).corners)])
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(radius: 50), store: InMemoryDataStore())
        // A walk from 400 m west to 800 m east of the border.
        for sample in Walk.line(fromEast: -400, north: 0, toEast: 800, north: 0, step: 10) {
            try await engine.process(sample)
        }
        let snapshot = await engine.snapshot()
        let coverage = DiscoveryStatistics.coverage(of: snapshot, in: [west, east])
        XCTAssertEqual(coverage[0].discoveredSquareMeters, 400 * 100 + .pi * 2_500 / 2, accuracy: 600)
        XCTAssertEqual(coverage[1].discoveredSquareMeters, 800 * 100 + .pi * 2_500 / 2, accuracy: 600)
        XCTAssertEqual(coverage[0].discoveredSquareMeters + coverage[1].discoveredSquareMeters, snapshot.totalAreaSquareMeters, accuracy: 50)
        XCTAssertGreaterThan(coverage[1].fraction, coverage[0].fraction)
    }
}
