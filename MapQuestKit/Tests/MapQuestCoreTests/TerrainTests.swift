import XCTest
@testable import MapQuestCore

/// Terrain given by a function of the metric offset (east, north) from `Walk.origin`.
struct FunctionTerrain: TerrainModel {
    let identifier = "test"
    let isFlat = false
    let height: @Sendable (Double, Double) -> Double

    func elevation(at point: WorldPoint) -> Double {
        let c = WebMercator.unproject(point)
        let north = (c.latitude - Walk.origin.latitude) * 111_320
        let east = (c.longitude - Walk.origin.longitude) * 111_320 * cos(Walk.origin.latitude * .pi / 180)
        return height(east, north)
    }
}

final class TerrainTests: XCTestCase {
    func encode(south: Double, west: Double, latStep: Double, lonStep: Double, rows: Int, cols: Int, values: [Int16]) -> Data {
        var data = Data("MQDEM001".utf8)
        for v in [south, west, latStep, lonStep] { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        for v in [Int32(rows), Int32(cols)] { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        for v in values { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    func testGridTerrainReadsAndInterpolates() throws {
        // 2 × 3 grid: south row 30 m, 31 m, 32 m; north row 40 m, no data, 42 m.
        let data = encode(south: 52.0, west: 13.0, latStep: 0.01, lonStep: 0.01, rows: 2, cols: 3,
                          values: [300, 310, 320, 400, GridTerrain.noData, 420])
        let terrain = try GridTerrain(identifier: "test", data: data, fallback: 35)
        XCTAssertEqual(terrain.rows, 2)
        XCTAssertEqual(terrain.columns, 3)
        XCTAssertEqual(terrain.elevation(latitude: 52.0, longitude: 13.0), 30, accuracy: 1e-9)
        XCTAssertEqual(terrain.elevation(latitude: 52.0, longitude: 13.005), 30.5, accuracy: 1e-9)
        XCTAssertEqual(terrain.elevation(latitude: 52.005, longitude: 13.0), 35, accuracy: 1e-9)
        // Next to the no-data cell only valid neighbours count (31 m, weight 0.75; no data, weight 0.25).
        XCTAssertEqual(terrain.elevation(latitude: 52.0025, longitude: 13.01), 31, accuracy: 1e-6)
        XCTAssertEqual(terrain.elevation(latitude: 51.0, longitude: 13.0), 35, "outside → fallback")
        XCTAssertFalse(terrain.isFlat)
        XCTAssertThrowsError(try GridTerrain(identifier: "x", data: Data("nope".utf8), fallback: 0))
        XCTAssertThrowsError(try GridTerrain(identifier: "x", data: data.prefix(50), fallback: 0))
    }

    func testTerrainSweepOnFlatGroundMatchesTheExactSweep() {
        let low = Viewshed.Crossing(entry: 50, exit: 60, top: 10, blocks: true, building: 0)
        var seen = Set<Int>()
        let visible = Viewshed.sweep([low], eyeElevation: 35 + 30, ground: { _ in 35 }, length: 200, seen: &seen)
        XCTAssertEqual(seen, [0])
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible[0].1, 50, accuracy: 1e-9)
        XCTAssertEqual(visible[1].0, 90, accuracy: Viewshed.groundStep(at: 90), "shadow ends at 60·30/20 = 90 m")
        XCTAssertEqual(visible[1].1, 200, accuracy: 1e-9)
    }

    func testRidgeHidesTheValleyBehindIt() {
        // Street level; a 20 m ridge 100–120 m away, valley behind, rising again after 300 m.
        let ground: (Double) -> Double = { t in
            if t >= 100 && t <= 120 { return 55 }
            if t > 300 { return 35 + (t - 300) * 0.5 }
            return 35
        }
        var seen = Set<Int>()
        let visible = Viewshed.sweep([], eyeElevation: 36.7, ground: ground, length: 600, seen: &seen)
        XCTAssertEqual(visible.first?.0, 0)
        // From below, the ridge's front face is visible but not its flat top.
        XCTAssertTrue(visible.contains { $0.0 <= 98 && $0.1 >= 100 - 1e-9 }, "the ridge's face is visible")
        XCTAssertFalse(visible.contains { $0.0 < 110 && $0.1 > 110 }, "its flat top is not")
        XCTAssertFalse(visible.contains { $0.0 < 200 && $0.1 > 200 }, "the valley behind the ridge is hidden")
        XCTAssertTrue(visible.contains { $0.1 >= 590 }, "the far slope rises into view")
    }

    func testHilltopSeesFurtherThanThePlain() async throws {
        // A cone-shaped hill, 70 m high, 600 m radius (like Teufelsberg above its surroundings).
        let hill = FunctionTerrain { east, north in
            let r = (east * east + north * north).squareRoot()
            return 50 + max(0, 70 * (1 - r / 600))
        }
        let model = ViewshedDiscoveryModel(buildings: InMemoryBuildingSource([]), terrain: hill)
        XCTAssertNotEqual(model.layer, "viewshed-v2", "real terrain gives its own layer")

        var top = Walk.sample(east: 0, north: 0, second: 0)
        top.altitude = 120 + 1.5
        top.verticalAccuracy = 3
        let heights = model.heights(for: top)
        XCTAssertEqual(heights.eye, 1.7, accuracy: 1e-9, "standing on the ground")
        XCTAssertGreaterThan(heights.effective, 30, "but high above the surrounding terrain")
        let onTop = try await model.viewshed(for: top)
        XCTAssertGreaterThan(onTop.viewDistance, 500)

        var foot = Walk.sample(east: 1_500, north: 0, second: 1)
        foot.altitude = 51.5
        foot.verticalAccuracy = 3
        let atFoot = try await model.viewshed(for: foot)
        XCTAssertEqual(atFoot.viewDistance, 150, accuracy: 1)
        XCTAssertGreaterThan(onTop.polygons.areaSquareMeters, atFoot.polygons.areaSquareMeters * 4)
    }

    func testLayerIDsTrackParameters() {
        let source = InMemoryBuildingSource([])
        let standard = ViewshedDiscoveryModel(buildings: source)
        XCTAssertEqual(standard.layer, "viewshed-v2")
        var config = ViewshedConfiguration()
        config.baseDistance = 200
        let wider = ViewshedDiscoveryModel(buildings: source, configuration: config)
        XCTAssertTrue(wider.layer.rawValue.hasPrefix("viewshed-v2-flat35-"))
        XCTAssertEqual(wider.layer, ViewshedDiscoveryModel(buildings: source, configuration: config).layer, "stable")
        config.rayCount = 360
        XCTAssertNotEqual(ViewshedDiscoveryModel(buildings: source, configuration: config).layer, wider.layer)
        XCTAssertEqual(CircleDiscoveryModel(radius: 80).layer, "circle-80m")
    }

    func testAltitudeForEyeHeightInvertsEyeHeight() {
        let config = ViewshedConfiguration()
        for height in [1.7, 5, 30, 200] {
            let altitude = config.altitude(forEyeHeight: height, groundElevation: 40, verticalAccuracy: 2)
            XCTAssertEqual(config.eyeHeight(altitude: altitude, verticalAccuracy: 2, groundElevation: 40), height, accuracy: 1e-9)
        }
    }
}
