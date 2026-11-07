import XCTest
@testable import MapQuestCore

final class GeometryTests: XCTestCase {
    func square(_ minX: Int64, _ minY: Int64, _ size: Int64) -> WorldRing {
        [
            WorldPoint(x: minX, y: minY), WorldPoint(x: minX + size, y: minY),
            WorldPoint(x: minX + size, y: minY + size), WorldPoint(x: minX, y: minY + size),
        ]
    }

    func testAreaAndContainmentWithHole() {
        let polygon = WorldPolygon(exterior: square(1_000, 1_000, 100), holes: [square(1_040, 1_040, 20)])
        XCTAssertEqual(polygon.area, 100 * 100 - 20 * 20)
        XCTAssertTrue(polygon.contains(WorldPoint(x: 1_010, y: 1_010)))
        XCTAssertFalse(polygon.contains(WorldPoint(x: 1_050, y: 1_050)), "inside the hole")
        XCTAssertFalse(polygon.contains(WorldPoint(x: 900, y: 1_050)))
        XCTAssertEqual(polygon.bounds, WorldRect(minX: 1_000, minY: 1_000, maxX: 1_100, maxY: 1_100))
        XCTAssertEqual(polygon.vertexCount, 8)
    }

    func testSignedAreaOrientation() {
        let ring = square(0, 0, 10)
        let reversed = Array(ring.reversed())
        XCTAssertEqual(WorldPolygon.signedArea(of: ring), -WorldPolygon.signedArea(of: reversed))
        XCTAssertEqual(abs(WorldPolygon.signedArea(of: ring)), 100)
    }

    func testAreaInSquareMetres() {
        // A 100 m × 100 m square in Berlin.
        let mpu = WebMercator.metersPerUnit(atLatitude: 52.52)
        let side = Int64((100 / mpu).rounded())
        let origin = WebMercator.project(GeoCoordinate(latitude: 52.52, longitude: 13.40))
        let polygon = WorldPolygon(exterior: square(origin.x, origin.y, side))
        XCTAssertEqual(polygon.areaSquareMeters, 10_000, accuracy: 10)
    }

    func testCodecRoundTrip() throws {
        let origin = WorldPoint(x: 2_300_000_000, y: 1_400_000_000)
        let polygon = WorldPolygon(
            exterior: square(origin.x + 10, origin.y + 20, 65_536),
            holes: [square(origin.x + 1_000, origin.y + 1_000, 300), [
                WorldPoint(x: origin.x + 5_000, y: origin.y + 5_000),
                WorldPoint(x: origin.x + 5_100, y: origin.y + 5_000),
                WorldPoint(x: origin.x + 5_050, y: origin.y + 4_900),
            ]]
        )
        let data = PolygonCodec.encode(polygon, origin: origin)
        // Tile-local coordinates need only a few bytes per vertex.
        XCTAssertLessThan(data.count, polygon.vertexCount * 6 + 8)
        let decoded = try PolygonCodec.decodePolygon(data, origin: origin)
        XCTAssertEqual(decoded, polygon)
    }

    func testCodecHandlesExtremeValues() throws {
        let rings: [[WorldPoint]] = [[
            WorldPoint(x: 0, y: WebMercator.worldSize - 1),
            WorldPoint(x: WebMercator.worldSize - 1, y: 0),
            WorldPoint(x: -5, y: -7),
        ]]
        let decoded = try PolygonCodec.decodeRings(PolygonCodec.encode(rings: rings))
        XCTAssertEqual(decoded, rings)
    }

    func testCodecRejectsGarbage() {
        XCTAssertThrowsError(try PolygonCodec.decodeRings(Data()))
        XCTAssertThrowsError(try PolygonCodec.decodeRings(Data([9, 1])))
        XCTAssertThrowsError(try PolygonCodec.decodeRings(Data([1, 1, 2, 0x80])))
        XCTAssertThrowsError(try PolygonCodec.decodeRings(Data([1, 0xFF, 0xFF, 0xFF, 0x7F])))
    }

    func testZigZag() {
        for value: Int64 in [0, -1, 1, -2, 2, Int64.max, Int64.min, 123_456_789, -987_654_321] {
            XCTAssertEqual(PolygonCodec.unzigzag(PolygonCodec.zigzag(value)), value)
        }
        XCTAssertEqual(PolygonCodec.zigzag(0), 0)
        XCTAssertEqual(PolygonCodec.zigzag(-1), 1)
        XCTAssertEqual(PolygonCodec.zigzag(1), 2)
    }
}
