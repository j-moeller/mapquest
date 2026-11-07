import XCTest
@testable import MapQuestCore

final class LoD1MeshTests: XCTestCase {
    let frame = LocalFrame(origin: WebMercator.project(Walk.origin))

    func box(_ id: Int64, east: Double, north: Double, size: Double, height: Double, minHeight: Double = 0, clockwise: Bool = false, hole: Bool = false) -> Building {
        var ring = [(0.0, 0.0), (size, 0.0), (size, size), (0.0, size)].map {
            WebMercator.project(Walk.coordinate(east: east + $0.0, north: north + $0.1))
        }
        if clockwise { ring.reverse() }
        var holes: [WorldRing] = []
        if hole {
            holes = [[(0.3, 0.3), (0.3, 0.7), (0.7, 0.7), (0.7, 0.3)].map {
                WebMercator.project(Walk.coordinate(east: east + $0.0 * size, north: north + $0.1 * size))
            }]
        }
        return Building(id: id, footprint: WorldPolygon(exterior: ring, holes: holes), height: height, minHeight: minHeight)
    }

    func testBoxHasWallsAndRoofWithOutwardNormals() {
        for clockwise in [false, true] {
            let building = box(1, east: 10, north: 20, size: 10, height: 15, clockwise: clockwise)
            let mesh = LoD1MeshBuilder.mesh(for: [building], frame: frame) { _ in true }
            XCTAssertEqual(mesh.triangleCount, 4 * 2 + 2)
            // Centre of the box in local coordinates: 15 m east, 25 m north (= −25 south).
            let cx: Float = 15, cz: Float = -25
            for t in stride(from: 0, to: mesh.indices.count, by: 3) {
                let i = Int(mesh.indices[t])
                let nx = mesh.normals[3 * i], ny = mesh.normals[3 * i + 1], nz = mesh.normals[3 * i + 2]
                if ny == 0 {
                    // Wall: the normal points away from the box centre.
                    let x = mesh.positions[3 * i], z = mesh.positions[3 * i + 2]
                    let wallMidX = (x + mesh.positions[3 * Int(mesh.indices[t + 1])]) / 2
                    let wallMidZ = (z + mesh.positions[3 * Int(mesh.indices[t + 1]) + 2]) / 2
                    XCTAssertGreaterThan(nx * (wallMidX - cx) + nz * (wallMidZ - cz), 0, "clockwise input: \(clockwise)")
                } else {
                    XCTAssertEqual(ny, 1)
                }
                // Counter-clockwise seen from the normal's side.
                let a = Int(mesh.indices[t]), b = Int(mesh.indices[t + 1]), c = Int(mesh.indices[t + 2])
                func v(_ k: Int) -> (Float, Float, Float) { (mesh.positions[3 * k], mesh.positions[3 * k + 1], mesh.positions[3 * k + 2]) }
                let (p, q, r) = (v(a), v(b), v(c))
                let u = (q.0 - p.0, q.1 - p.1, q.2 - p.2), w = (r.0 - p.0, r.1 - p.1, r.2 - p.2)
                let cross = (u.1 * w.2 - u.2 * w.1, u.2 * w.0 - u.0 * w.2, u.0 * w.1 - u.1 * w.0)
                XCTAssertGreaterThan(cross.0 * nx + cross.1 * ny + cross.2 * nz, 0)
            }
            let topY = stride(from: 1, to: mesh.positions.count, by: 3).map { mesh.positions[$0] }.max()
            XCTAssertEqual(topY, 15)
        }
    }

    func testCourtyardAndRaisedBuilding() {
        let courtyard = box(2, east: 0, north: 0, size: 40, height: 20, hole: true)
        var mesh = LoD1MeshBuilder.mesh(for: [courtyard], frame: frame) { _ in false }
        XCTAssertEqual(mesh.triangleCount, 8 * 2 + 8, "outer and courtyard walls, roof with a hole")
        XCTAssertEqual(Array(mesh.colors.prefix(4)), [0.20, 0.22, 0.29, 1])

        let bridge = box(3, east: 0, north: 0, size: 10, height: 12, minHeight: 6)
        mesh = LoD1MeshBuilder.mesh(for: [bridge], frame: frame) { _ in true }
        XCTAssertEqual(mesh.triangleCount, 8 + 2 + 2, "walls, roof and underside")
        let lowest = stride(from: 1, to: mesh.positions.count, by: 3).map { mesh.positions[$0] }.min()
        XCTAssertEqual(lowest, 6)
    }

    func testInteriorPointOfConcaveFootprint() {
        // An L-shaped footprint whose bounding-box centre lies outside.
        let l = [(0.0, 0.0), (40.0, 0.0), (40.0, 10.0), (10.0, 10.0), (10.0, 40.0), (0.0, 40.0)].map {
            WebMercator.project(Walk.coordinate(east: $0.0, north: $0.1))
        }
        let building = Building(id: 4, footprint: WorldPolygon(exterior: l), height: 10)
        XCTAssertFalse(building.footprint.contains(building.bounds.center))
        XCTAssertTrue(building.footprint.contains(LoD1MeshBuilder.interiorPoint(of: building)))
    }

    func testLocalFrameRoundTrip() {
        let p = WebMercator.project(Walk.coordinate(east: 120, north: -80))
        let local = frame.local(p)
        XCTAssertEqual(local.x, 120, accuracy: 0.5)
        XCTAssertEqual(local.z, 80, accuracy: 0.5, "south is +z")
        let back = frame.world(x: local.x, z: local.z)
        XCTAssertEqual(back.x, p.x, accuracy: 1)
        XCTAssertEqual(back.y, p.y, accuracy: 1)
    }
}
