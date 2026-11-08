import XCTest
@testable import MapQuestCore

final class MultiCityTests: XCTestCase {
    /// A 3 × 3 km grid at constant `elevation` around a centre.
    func grid(_ identifier: String, center: GeoCoordinate, elevation: Double) -> GridTerrain {
        let rows = 101, columns = 101
        return GridTerrain(
            identifier: identifier, south: center.latitude - 0.0135, west: center.longitude - 0.022,
            latitudeStep: 0.00027, longitudeStep: 0.00044, rows: rows, columns: columns,
            decimetres: [Int16](repeating: Int16(elevation * 10), count: rows * columns), fallback: 35
        )
    }

    let berlin = GeoCoordinate(latitude: 52.5200, longitude: 13.4050)
    let braunschweig = GeoCoordinate(latitude: 52.2640, longitude: 10.5240)

    func testCompositeTerrainAnswersPerCity() {
        let terrain = CompositeTerrain([grid("berlin", center: berlin, elevation: 36), grid("braunschweig", center: braunschweig, elevation: 74)], fallback: 35)
        XCTAssertEqual(terrain.identifier, "berlin+braunschweig")
        XCTAssertEqual(terrain.elevation(at: WebMercator.project(berlin)), 36, accuracy: 1e-9)
        XCTAssertEqual(terrain.elevation(at: WebMercator.project(braunschweig)), 74, accuracy: 1e-9)
        let hamburg = WebMercator.project(GeoCoordinate(latitude: 53.55, longitude: 9.99))
        XCTAssertFalse(terrain.hasData(at: hamburg))
        XCTAssertEqual(terrain.elevation(at: hamburg), 35)
        XCTAssertEqual(CompositeTerrain([grid("berlin", center: berlin, elevation: 36)], fallback: 35).identifier, "berlin", "one city: same layer as before")
    }

    func testPositionsWithoutKnownGroundAreStreetLevel() {
        // Only Berlin has terrain: a street-level fix in Braunschweig (75 m) must not look like a viewpoint.
        let terrain = CompositeTerrain([grid("berlin", center: berlin, elevation: 36)], fallback: 35)
        let model = ViewshedDiscoveryModel(buildings: InMemoryBuildingSource([]), terrain: terrain)
        let street = LocationSample(coordinate: braunschweig, altitude: 77, verticalAccuracy: 3, timestamp: Date())
        XCTAssertEqual(model.heights(for: street).eye, model.configuration.streetEyeHeight)
        // With Braunschweig's terrain the same fix is street level for the right reason, and a tower is high.
        let both = CompositeTerrain([grid("berlin", center: berlin, elevation: 36), grid("braunschweig", center: braunschweig, elevation: 75)], fallback: 35)
        let known = ViewshedDiscoveryModel(buildings: InMemoryBuildingSource([]), terrain: both)
        XCTAssertEqual(known.heights(for: street).eye, known.configuration.streetEyeHeight, accuracy: 1e-9)
        let tower = LocationSample(coordinate: braunschweig, altitude: 75 + 60, verticalAccuracy: 3, timestamp: Date())
        XCTAssertGreaterThan(known.heights(for: tower).eye, 40)
    }

    func testCompositeBuildingCacheCombinesCities() async throws {
        func building(_ id: Int64, at c: GeoCoordinate) -> Building {
            let p = WebMercator.project(c)
            return Building(id: id, footprint: WorldPolygon(exterior: [p, WorldPoint(x: p.x + 100, y: p.y), WorldPoint(x: p.x + 100, y: p.y + 100), WorldPoint(x: p.x, y: p.y + 100)]), height: 20)
        }
        let berlinTile = TileKey(containing: berlin, zoom: DataGrid.zoom)
        let bsTile = TileKey(containing: braunschweig, zoom: DataGrid.zoom)
        let composite = CompositeBuildingCache([
            InMemoryBuildingCache([building(1, at: berlin)], downloadedTiles: [berlinTile]),
            InMemoryBuildingCache([building(2, at: braunschweig)], downloadedTiles: [bsTile]),
        ])
        let inBerlin = try await composite.buildings(in: berlinTile.worldRect)
        let inBraunschweig = try await composite.buildings(in: bsTile.worldRect)
        XCTAssertEqual(inBerlin.map(\.id), [1])
        XCTAssertEqual(inBraunschweig.map(\.id), [2])
        let versionBS = try await composite.version(of: bsTile)
        XCTAssertEqual(versionBS, "memory:0")
        let none = try await composite.version(of: TileKey(zoom: DataGrid.zoom, x: bsTile.x + 5, y: bsTile.y))
        XCTAssertNil(none)
    }
}
