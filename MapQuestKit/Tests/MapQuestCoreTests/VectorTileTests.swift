import XCTest
@testable import MapQuestCore

/// Decoding and drawing plan of a real OpenFreeMap tile: zoom 14, Peine centre
/// (TestData/openfreemap-14-8657-5388.mvt; OpenMapTiles schema, © OpenStreetMap
/// contributors, ODbL). Reference values from the Python package mapbox-vector-tile.
final class VectorTileTests: XCTestCase {
    static let peine = TileKey(zoom: 14, x: 8657, y: 5388)

    static func fixture() throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("TestData/openfreemap-14-8657-5388.mvt"))
    }

    func testDecodesLayersFeaturesAndGeometry() throws {
        let tile = try VectorTile(data: Self.fixture())
        XCTAssertEqual(tile.layers["water"]?.features.count, 7)
        XCTAssertEqual(tile.layers["transportation"]?.features.count, 135)
        XCTAssertEqual(tile.layers["building"]?.features.count, 15)
        XCTAssertEqual(tile.layers["landcover"]?.features.count, 60)
        XCTAssertEqual(tile.layers["poi"]?.features.count, 505)
        XCTAssertEqual(tile.layers["water"]?.extent, 4096)

        let pool = try XCTUnwrap(tile.layers["water"]?.features.first)
        XCTAssertEqual(pool.type, .polygon)
        XCTAssertEqual(pool.className, "swimming_pool")
        XCTAssertEqual(pool.properties["id"], .number(97_853_167))
        XCTAssertEqual(Array(pool.paths[0].prefix(3)), [
            VectorTile.Point(x: 1131, y: 2216), VectorTile.Point(x: 1263, y: 2242), VectorTile.Point(x: 1247, y: 2325),
        ])
        XCTAssertEqual(pool.paths[0].first, pool.paths[0].last, "rings are closed")

        let area = try XCTUnwrap(tile.layers["transportation"]?.features.first)
        XCTAssertEqual(area.type, .polygon)
        XCTAssertEqual(area.properties["subclass"], .string("pedestrian"))
        XCTAssertEqual(area.paths[0], [
            VectorTile.Point(x: 1815, y: 205), VectorTile.Point(x: 1877, y: 179), VectorTile.Point(x: 1913, y: 222),
            VectorTile.Point(x: 1852, y: 247), VectorTile.Point(x: 1841, y: 218), VectorTile.Point(x: 1821, y: 225),
            VectorTile.Point(x: 1815, y: 205),
        ])
        let lake = try XCTUnwrap(tile.layers["water"]?.features.first { $0.className == "lake" })
        XCTAssertEqual(lake.paths.map(\.count), [22])
        XCTAssertEqual(tile.layers["transportation"]?.features.filter { $0.className == "trunk" }.count, 7)
        let parts = tile.layers["building"]?.features.reduce(0) { $0 + $1.paths.count } ?? 0
        XCTAssertGreaterThanOrEqual(parts, 1_560, "buildings are merged into multipolygons")
    }

    func testDecodesOnlyRequestedLayers() throws {
        let tile = try VectorTile(data: Self.fixture(), only: MapRenderPlan.layers)
        XCTAssertNil(tile.layers["poi"])
        XCTAssertNil(tile.layers["transportation_name"])
        XCTAssertNil(tile.layers["place"])
        XCTAssertEqual(tile.layers["water"]?.features.count, 7)
        XCTAssertEqual(Set(tile.layers.keys), MapRenderPlan.layers)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try VectorTile(data: Data([0x1A, 0xFF, 0xFF, 0xFF, 0x0F])))
        XCTAssertNoThrow(try VectorTile(data: Data()))
    }

    func testDrawingPlanHasNoLabelsAndKeepsOrder() throws {
        let tile = try VectorTile(data: Self.fixture(), only: MapRenderPlan.layers)
        let commands = MapRenderPlan.commands(for: tile, source: Self.peine, target: Self.peine)
        let roles = commands.map(\.role)
        XCTAssertTrue(roles.contains(.water))
        XCTAssertTrue(roles.contains(.building))
        XCTAssertTrue(roles.contains(.trunk))
        XCTAssertTrue(roles.contains(.grass))
        // Land use below water, water below buildings, buildings below roads, casings below fills.
        func first(_ role: MapRole) -> Int { roles.firstIndex(of: role) ?? -1 }
        XCTAssertLessThan(first(.industrial), first(.water))
        XCTAssertLessThan(first(.water), first(.building))
        XCTAssertLessThan(first(.building), first(.trunk))
        XCTAssertLessThan(first(.roadCasing), first(.minor))
        XCTAssertLessThan(first(.minor), first(.trunk))
        // Everything lies on or near the 512-pixel tile.
        for command in commands {
            for shape in command.shapes {
                let xs = shape.flatMap { $0.map(\.x) }, ys = shape.flatMap { $0.map(\.y) }
                XCTAssertLessThanOrEqual(xs.min() ?? 0, 512 + 100)
                XCTAssertGreaterThanOrEqual(xs.max() ?? 0, -100)
                XCTAssertLessThanOrEqual(ys.min() ?? 0, 512 + 100)
                XCTAssertGreaterThanOrEqual(ys.max() ?? 0, -100)
            }
        }
        // The pool at tile coordinates (1131, 2216) is at 1131 / 4096 × 512 pixels.
        let water = commands.filter { $0.role == .water && $0.kind == .fill }.flatMap(\.shapes)
        XCTAssertTrue(water.contains { $0[0][0] == MapPixel(x: 1131.0 / 8, y: 2216.0 / 8) })
    }

    func testOverzoomDrawsTheMatchingQuarter() throws {
        let tile = try VectorTile(data: Self.fixture(), only: MapRenderPlan.layers)
        // Zoom 16, the tile two below and one to the right of the source's top-left quarter.
        let target = TileKey(zoom: 16, x: 8657 * 4 + 1, y: 5388 * 4 + 2)
        let commands = MapRenderPlan.commands(for: tile, source: Self.peine, target: target)
        XCTAssertFalse(commands.isEmpty)
        // The pool (1131, 2216) lies in sub-tile (1, 2) of 4 × 4 (1024-unit cells): pixel ((1131 − 1024) / 1024 × 512, (2216 − 2048) / 1024 × 512).
        let water = commands.filter { $0.role == .water && $0.kind == .fill }.flatMap(\.shapes)
        XCTAssertTrue(water.contains { $0[0][0] == MapPixel(x: 107.0 / 2, y: 168.0 / 2) })
        // Roads are wider at zoom 16 than at 14 (minor roads: 6 instead of 2.4 points).
        func width(_ role: MapRole, _ commands: [MapDrawCommand]) -> Double? {
            for command in commands where command.role == role {
                if case let .stroke(width, _) = command.kind { return width }
            }
            return nil
        }
        let role = try XCTUnwrap([MapRole.minor, .service, .tertiary, .trunk].first { width($0, commands) != nil })
        let wide = try XCTUnwrap(width(role, commands))
        let normal = try XCTUnwrap(width(role, MapRenderPlan.commands(for: tile, source: Self.peine, target: Self.peine)))
        XCTAssertGreaterThan(wide / normal, 1.9)
    }

    func testWidthStops() {
        let stops: [(zoom: Int, width: Double)] = [(10, 1), (12, 4), (14, 8)]
        XCTAssertNil(MapRenderPlan.width(stops, zoom: 9))
        XCTAssertEqual(MapRenderPlan.width(stops, zoom: 10) ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(MapRenderPlan.width(stops, zoom: 11) ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(MapRenderPlan.width(stops, zoom: 14) ?? 0, 8, accuracy: 1e-9)
        XCTAssertEqual(MapRenderPlan.width(stops, zoom: 16) ?? 0, 32, accuracy: 1e-9)
    }

    func testTileJSON() throws {
        let json = #"{"tilejson":"3.0.0","tiles":["https://tiles.openfreemap.org/planet/20261101_080013_pt/{z}/{x}/{y}.pbf"],"maxzoom":14,"minzoom":0}"#
        let tileJSON = try JSONDecoder().decode(TileJSON.self, from: Data(json.utf8))
        XCTAssertEqual(tileJSON.maxzoom, 14)
        XCTAssertEqual(tileJSON.url(for: Self.peine)?.absoluteString, "https://tiles.openfreemap.org/planet/20261101_080013_pt/14/8657/5388.pbf")
    }
}
