import XCTest
@testable import MapQuestCore

final class ViewshedTests: XCTestCase {
    let eyeCoordinate = Walk.origin
    var eye: WorldPoint { WebMercator.project(eyeCoordinate) }

    /// An axis-aligned building given in metres east/north of the eye.
    func building(_ id: Int64, east e0: Double, north n0: Double, east e1: Double, north n1: Double, height: Double, minHeight: Double = 0) -> Building {
        let corners = [
            Walk.coordinate(east: e0, north: n0), Walk.coordinate(east: e1, north: n0),
            Walk.coordinate(east: e1, north: n1), Walk.coordinate(east: e0, north: n1),
        ].map(WebMercator.project)
        return Building(id: id, footprint: WorldPolygon(exterior: corners), height: height, minHeight: minHeight)
    }

    func isVisible(_ result: ViewshedResult, east: Double, north: Double) -> Bool {
        let p = WebMercator.project(Walk.coordinate(east: east, north: north))
        return result.polygons.contains { $0.contains(p) }
    }

    func testOpenFieldIsADisk() {
        let result = Viewshed.compute(eye: eye, eyeHeight: 1.7, viewDistance: 150, buildings: [])
        XCTAssertEqual(result.polygons.count, 1)
        XCTAssertEqual(result.polygons.areaSquareMeters, .pi * 150 * 150, accuracy: .pi * 150 * 150 * 0.01)
        XCTAssertTrue(result.seenBuildingIDs.isEmpty)
    }

    func testWallHidesWhatIsBehindItAndIsDiscovered() {
        // A 20 m high, 200 m wide block 30–40 m north of the eye.
        let wall = building(1, east: -100, north: 30, east: 100, north: 40, height: 20)
        let result = Viewshed.compute(eye: eye, eyeHeight: 1.7, viewDistance: 150, buildings: [wall])
        XCTAssertEqual(result.seenBuildingIDs, [1])
        XCTAssertTrue(isVisible(result, east: 0, north: 20), "in front of the wall")
        XCTAssertTrue(isVisible(result, east: 0, north: 35), "the wall itself is discovered")
        XCTAssertFalse(isVisible(result, east: 0, north: 60), "behind the wall")
        XCTAssertFalse(isVisible(result, east: 50, north: 100), "behind the wall, diagonally")
        XCTAssertTrue(isVisible(result, east: 0, north: -100), "the open side")
        XCTAssertTrue(isVisible(result, east: 140, north: 40), "past the end of the wall")
    }

    func testShadowOfALowerBuildingFromAbove() {
        // Eye 30 m above ground; a 10 m building 50–60 m away.
        // Its shadow ends at 60 · 30 / (30 − 10) = 90 m.
        let low = Viewshed.Crossing(entry: 50, exit: 60, top: 10, blocks: true, building: 0)
        var seen = Set<Int>()
        let visible = Viewshed.sweep([low], eyeHeight: 30, length: 200, seen: &seen)
        XCTAssertEqual(seen, [0])
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible[0].0, 0)
        XCTAssertEqual(visible[0].1, 50, accuracy: 1e-9)
        XCTAssertEqual(visible[1].0, 90, accuracy: 1e-9)
        XCTAssertEqual(visible[1].1, 200, accuracy: 1e-9)
    }

    func testTallBuildingBlocksEverythingBehindItButTallerLandmarksStayVisible() {
        // From 1.7 m, a 20 m house 50 m away hides everything below a slope of 18.3/50.
        let house = Viewshed.Crossing(entry: 50, exit: 60, top: 20, blocks: true, building: 0)
        let hiddenHouse = Viewshed.Crossing(entry: 100, exit: 110, top: 20, blocks: true, building: 1)
        let tower = Viewshed.Crossing(entry: 300, exit: 320, top: 200, blocks: true, building: 2)
        var seen = Set<Int>()
        let visible = Viewshed.sweep([tower, hiddenHouse, house], eyeHeight: 1.7, length: 400, seen: &seen)
        XCTAssertEqual(seen, [0, 2], "the tower rises above the house's roof line")
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].1, 50, accuracy: 1e-9, "the ground ends at the first wall")

        // Right behind a 20 m house, even a 200 m tower 300 m away is hidden.
        seen = []
        let close = Viewshed.Crossing(entry: 20, exit: 30, top: 20, blocks: true, building: 0)
        _ = Viewshed.sweep([tower, close], eyeHeight: 1.7, length: 400, seen: &seen)
        XCTAssertEqual(seen, [0])
    }

    func testPassagesDoNotBlock() {
        let bridge = Viewshed.Crossing(entry: 20, exit: 30, top: 12, blocks: false, building: 0)
        var seen = Set<Int>()
        let visible = Viewshed.sweep([bridge], eyeHeight: 1.7, length: 100, seen: &seen)
        XCTAssertEqual(seen, [0])
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].1, 100, accuracy: 1e-9)
    }

    func testStandingInsideABuilding() {
        let around = building(7, east: -10, north: -10, east: 10, north: 10, height: 25)
        let result = Viewshed.compute(eye: eye, eyeHeight: 1.7, viewDistance: 150, buildings: [around])
        XCTAssertEqual(result.seenBuildingIDs, [7])
        XCTAssertTrue(isVisible(result, east: 0, north: 100), "the building one stands in does not block the view")
    }

    func testCourtyardIsHiddenFromTheStreet() {
        // A closed block with a courtyard hole, 20–80 m north.
        let corners = [(-60.0, 20.0), (60.0, 20.0), (60.0, 80.0), (-60.0, 80.0)]
        let yard = [(-40.0, 35.0), (-40.0, 65.0), (40.0, 65.0), (40.0, 35.0)]
        let footprint = WorldPolygon(
            exterior: corners.map { WebMercator.project(Walk.coordinate(east: $0.0, north: $0.1)) },
            holes: [yard.map { WebMercator.project(Walk.coordinate(east: $0.0, north: $0.1)) }]
        )
        let block = Building(id: 3, footprint: footprint, height: 22)
        let result = Viewshed.compute(eye: eye, eyeHeight: 1.7, viewDistance: 150, buildings: [block])
        XCTAssertEqual(result.seenBuildingIDs, [3])
        XCTAssertFalse(isVisible(result, east: 0, north: 50), "courtyard")
        XCTAssertTrue(isVisible(result, east: 0, north: 25), "the block itself")
    }

    /// A Manhattan-like grid of 20 m high blocks with 20 m wide streets.
    func cityGrid() -> [Building] {
        var buildings: [Building] = []
        var id: Int64 = 100
        for i in -8...8 {
            for j in -8...8 {
                let e = Double(i) * 100 + 10, n = Double(j) * 100 + 10
                buildings.append(building(id, east: e, north: n, east: e + 80, north: n + 80, height: 20))
                id += 1
            }
        }
        return buildings
    }

    func testStreetLevelSeesAlongStreetsOnly() {
        let result = Viewshed.compute(eye: eye, eyeHeight: 1.7, viewDistance: 300, buildings: cityGrid())
        XCTAssertTrue(isVisible(result, east: 250, north: 0), "along the street")
        XCTAssertTrue(isVisible(result, east: 0, north: -250), "along the cross street")
        XCTAssertFalse(isVisible(result, east: 150, north: 150), "behind the corner block")
        XCTAssertEqual(result.seenBuildingIDs.count, 4 + 4 * 4, accuracy: 10)
    }

    func testHigherViewpointRevealsMore() {
        let config = ViewshedConfiguration()
        let street = Viewshed.compute(eye: eye, eyeHeight: 1.7, viewDistance: config.viewDistance(eyeHeight: 1.7), buildings: cityGrid())
        let roof = Viewshed.compute(eye: eye, eyeHeight: 40, viewDistance: config.viewDistance(eyeHeight: 40), buildings: cityGrid())
        XCTAssertGreaterThan(roof.polygons.areaSquareMeters, street.polygons.areaSquareMeters * 2)
        XCTAssertGreaterThan(roof.seenBuildingIDs.count, street.seenBuildingIDs.count * 2)
        // From 40 m, a 20 m block casts a shadow of b · 40/20 = 2b: the next street is partly visible.
        XCTAssertTrue(isVisible(roof, east: 500, north: 0))
    }

    func testEyeHeightIgnoresNoiseAndUnreliableAltitudes() {
        let config = ViewshedConfiguration()
        // Street level with typical GNSS noise.
        XCTAssertEqual(config.eyeHeight(altitude: 44, verticalAccuracy: 4, groundElevation: 35), 1.7)
        // Unknown or poor vertical accuracy.
        XCTAssertEqual(config.eyeHeight(altitude: 200, verticalAccuracy: -1, groundElevation: 35), 1.7)
        XCTAssertEqual(config.eyeHeight(altitude: 200, verticalAccuracy: 30, groundElevation: 35), 1.7)
        // The Fernsehturm's viewing deck (≈ 203 m above ground).
        XCTAssertEqual(config.eyeHeight(altitude: 238, verticalAccuracy: 5, groundElevation: 35), 1.7 + 203 - 5 - 8, accuracy: 1e-9)
        XCTAssertEqual(config.viewDistance(eyeHeight: 1.7), 150)
        XCTAssertEqual(config.viewDistance(eyeHeight: 200), 2_000)
    }

    func testViewshedModelUsesBuildingSourceAndFeedsTheEngine() async throws {
        let model = ViewshedDiscoveryModel(buildings: InMemoryBuildingSource(cityGrid()))
        XCTAssertEqual(model.layer, "viewshed-v1")
        let engine = DiscoveryEngine(model: model, store: InMemoryDataStore())
        // Walk along the street at north = 0.
        for sample in Walk.line(fromEast: -150, north: 0, toEast: 150, north: 0, step: 30) {
            try await engine.process(sample)
        }
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.regions.count, 1)
        let streetPoint = WebMercator.project(Walk.coordinate(east: 0, north: 0))
        let blockInterior = WebMercator.project(Walk.coordinate(east: 50, north: 50))
        let hiddenStreet = WebMercator.project(Walk.coordinate(east: 50, north: 200))
        XCTAssertTrue(snapshot.isDiscovered(streetPoint))
        XCTAssertTrue(snapshot.isDiscovered(blockInterior), "facing blocks are discovered entirely")
        XCTAssertFalse(snapshot.isDiscovered(hiddenStreet), "a parallel street two blocks away stays hidden")
    }
}
