import XCTest
@testable import MapQuestCore

final class PolygonOpsTests: XCTestCase {
    func square(_ minX: Int64, _ minY: Int64, _ size: Int64, clockwise: Bool = false) -> WorldPolygon {
        var ring: WorldRing = [
            WorldPoint(x: minX, y: minY), WorldPoint(x: minX + size, y: minY),
            WorldPoint(x: minX + size, y: minY + size), WorldPoint(x: minX, y: minY + size),
        ]
        if clockwise { ring.reverse() }
        return WorldPolygon(exterior: ring)
    }

    func totalArea(_ polygons: [WorldPolygon]) -> Double { polygons.reduce(0) { $0 + $1.area } }

    func testUnionOfOverlappingSquares() {
        let result = PolygonOps.union([square(0, 0, 100), square(50, 50, 100, clockwise: true)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(totalArea(result), 100 * 100 * 2 - 50 * 50)
    }

    func testUnionKeepsDisjointPartsSeparate() {
        let result = PolygonOps.union([square(0, 0, 100), square(1_000, 0, 100)])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(totalArea(result), 20_000)
    }

    func testUnionCreatesHoles() {
        // A ring of four bars around an empty centre.
        let bars = [
            WorldPolygon(exterior: WorldRect(minX: 0, minY: 0, maxX: 300, maxY: 100).corners),
            WorldPolygon(exterior: WorldRect(minX: 0, minY: 200, maxX: 300, maxY: 300).corners),
            WorldPolygon(exterior: WorldRect(minX: 0, minY: 0, maxX: 100, maxY: 300).corners),
            WorldPolygon(exterior: WorldRect(minX: 200, minY: 0, maxX: 300, maxY: 300).corners),
        ]
        let result = PolygonOps.union(bars)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].holes.count, 1)
        XCTAssertEqual(result[0].area, 300 * 300 - 100 * 100)
        XCTAssertFalse(result[0].contains(WorldPoint(x: 150, y: 150)))
        XCTAssertTrue(result[0].contains(WorldPoint(x: 50, y: 150)))
    }

    func testHolesAreRespectedRegardlessOfOrientation() {
        // Exterior and hole with the *same* orientation must still produce a hole.
        let outer = square(0, 0, 300).exterior
        let hole = square(100, 100, 100).exterior
        let result = PolygonOps.union([WorldPolygon(exterior: outer, holes: [hole])])
        XCTAssertEqual(totalArea(result), 300 * 300 - 100 * 100)
    }

    func testDifferenceAndIntersection() {
        let a = [square(0, 0, 100)]
        let b = [square(50, 0, 100)]
        XCTAssertEqual(totalArea(PolygonOps.difference(a, b)), 5_000)
        XCTAssertEqual(totalArea(PolygonOps.intersection(a, b)), 5_000)
        XCTAssertTrue(PolygonOps.intersects(a, b))
        XCTAssertFalse(PolygonOps.intersects(a, [square(500, 500, 10)]))
        // Touching along an edge has no area in common.
        XCTAssertFalse(PolygonOps.intersects(a, [square(100, 0, 100)]))
        XCTAssertEqual(totalArea(PolygonOps.difference(a, [])), 10_000)
        XCTAssertTrue(PolygonOps.difference([], a).isEmpty)
    }

    func testInflateMakesTouchingShapesOverlap() {
        let a = [square(0, 0, 100)]
        let b = [square(110, 0, 100)]
        XCTAssertFalse(PolygonOps.intersects(a, b))
        XCTAssertFalse(PolygonOps.intersects(PolygonOps.inflate(a, by: 6), b))
        XCTAssertTrue(PolygonOps.intersects(PolygonOps.inflate(a, by: 11), b))
        let grown = PolygonOps.inflate(a, by: 10)
        // 100² + 4·(100·10) + π·10² (rounded corners).
        XCTAssertEqual(totalArea(grown), 10_000 + 4_000 + .pi * 100, accuracy: 20)
    }

    func testCircleArea() {
        let circle = PolygonOps.circle(center: WorldPoint(x: 1_000_000, y: 1_000_000), radius: 10_000, segments: 128)
        XCTAssertEqual(circle.area, .pi * 10_000 * 10_000, accuracy: .pi * 10_000 * 10_000 * 0.001)
        XCTAssertTrue(circle.contains(WorldPoint(x: 1_000_000, y: 1_000_000)))
        XCTAssertFalse(circle.contains(WorldPoint(x: 1_010_001, y: 1_000_000)))
    }

    func testRectClip() {
        let circle = PolygonOps.circle(center: WorldPoint(x: 0, y: 0), radius: 1_000, segments: 256)
        let quarter = PolygonOps.clip([circle], to: WorldRect(minX: 0, minY: 0, maxX: 5_000, maxY: 5_000))
        XCTAssertEqual(quarter.count, 1)
        XCTAssertEqual(totalArea(quarter), .pi * 1_000 * 1_000 / 4, accuracy: 500)
        XCTAssertTrue(PolygonOps.clip([circle], to: WorldRect(minX: 5_000, minY: 5_000, maxX: 6_000, maxY: 6_000)).isEmpty)
        // A clip rect that contains everything returns the input area.
        XCTAssertEqual(totalArea(PolygonOps.clip([circle], to: WorldRect(minX: -5_000, minY: -5_000, maxX: 5_000, maxY: 5_000))), circle.area, accuracy: 1)
    }

    func testRectClipSplitsConcaveShapes() {
        // A "U" shape clipped by a rect across its arms gives two pieces.
        let u = PolygonOps.union([
            WorldPolygon(exterior: WorldRect(minX: 0, minY: 0, maxX: 100, maxY: 300).corners),
            WorldPolygon(exterior: WorldRect(minX: 200, minY: 0, maxX: 300, maxY: 300).corners),
            WorldPolygon(exterior: WorldRect(minX: 0, minY: 200, maxX: 300, maxY: 300).corners),
        ])
        let clipped = PolygonOps.clip(u, to: WorldRect(minX: -10, minY: 0, maxX: 310, maxY: 150))
        XCTAssertEqual(clipped.count, 2)
    }

    func testBufferOfPolyline() {
        let corridor = PolygonOps.buffer(polyline: [WorldPoint(x: 0, y: 0), WorldPoint(x: 1_000, y: 0)], radius: 100)
        XCTAssertEqual(corridor.count, 1)
        XCTAssertEqual(totalArea(corridor), 1_000 * 200 + .pi * 100 * 100, accuracy: 400)
    }

    func testSimplifyReducesVertices() {
        let circle = PolygonOps.circle(center: .zero, radius: 10_000, segments: 512)
        let simplified = PolygonOps.simplify([circle], epsilon: 50)
        XCTAssertEqual(simplified.count, 1)
        XCTAssertLessThan(simplified[0].vertexCount, circle.vertexCount / 4)
        XCTAssertEqual(simplified[0].area, circle.area, accuracy: circle.area * 0.01)
    }

    func testTriangulateWithHole() throws {
        let polygon = WorldPolygon(exterior: square(0, 0, 300).exterior, holes: [square(100, 100, 100).exterior])
        let triangles = try XCTUnwrap(PolygonOps.triangulate(polygon))
        XCTAssertTrue(triangles.allSatisfy { $0.count == 3 })
        let area = triangles.reduce(0) { $0 + abs(WorldPolygon.signedArea(of: $1)) }
        XCTAssertEqual(area, 300 * 300 - 100 * 100)
    }
}
