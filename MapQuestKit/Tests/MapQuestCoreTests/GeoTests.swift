import XCTest
@testable import MapQuestCore

final class GeoTests: XCTestCase {
    let brandenburgGate = GeoCoordinate(latitude: 52.516275, longitude: 13.377704)
    let alexanderplatz = GeoCoordinate(latitude: 52.521918, longitude: 13.413215)

    func testHaversineDistance() {
        // Brandenburger Tor – Alexanderplatz is about 2.47 km.
        let d = brandenburgGate.distance(to: alexanderplatz)
        XCTAssertEqual(d, 2_470, accuracy: 30)
    }

    func testProjectionRoundTrip() {
        let p = WebMercator.project(brandenburgGate)
        let back = WebMercator.unproject(p)
        XCTAssertEqual(back.latitude, brandenburgGate.latitude, accuracy: 1e-7)
        XCTAssertEqual(back.longitude, brandenburgGate.longitude, accuracy: 1e-7)
    }

    func testProjectionCorners() {
        let nw = WebMercator.project(GeoCoordinate(latitude: WebMercator.maxLatitude, longitude: -180))
        XCTAssertEqual(nw, WorldPoint(x: 0, y: 0))
        let center = WebMercator.project(GeoCoordinate(latitude: 0, longitude: 0))
        XCTAssertEqual(center, WorldPoint(x: 1 << 31, y: 1 << 31))
    }

    func testMetersPerUnitInBerlin() {
        let mpu = WebMercator.metersPerUnit(atLatitude: 52.52)
        XCTAssertEqual(mpu, 0.005_68, accuracy: 0.000_01)
        // A metric distance measured in projected units matches the haversine distance.
        let a = WebMercator.projectExact(brandenburgGate)
        let b = WebMercator.projectExact(alexanderplatz)
        let units = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        let meters = units * WebMercator.metersPerUnit(atLatitude: (brandenburgGate.latitude + alexanderplatz.latitude) / 2)
        XCTAssertEqual(meters, brandenburgGate.distance(to: alexanderplatz), accuracy: 5)
    }

    func testTileKeyMatchesSlippyMapFormula() {
        // Reference: standard slippy-map tile formula.
        let zoom = 16
        let n = pow(2.0, Double(zoom))
        let latRad = brandenburgGate.latitude * .pi / 180
        let expectedX = Int((brandenburgGate.longitude + 180) / 360 * n)
        let expectedY = Int((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n)
        let tile = TileKey(containing: brandenburgGate, zoom: zoom)
        XCTAssertEqual(tile.x, expectedX)
        XCTAssertEqual(tile.y, expectedY)
        XCTAssertEqual(tile.description, "16/\(expectedX)/\(expectedY)")
        XCTAssertTrue(tile.boundingBox.contains(brandenburgGate))
    }

    func testTileSizeInBerlin() {
        let tile = TileKey(containing: brandenburgGate, zoom: DiscoveryGrid.zoom)
        let edgeMeters = Double(TileKey.size(atZoom: tile.zoom)) * tile.metersPerUnit
        XCTAssertEqual(edgeMeters, 372, accuracy: 2)
    }

    func testTileRangeCoversBoundingBox() {
        let box = GeoBoundingBox(center: brandenburgGate, radius: 500)
        let range = TileRange(covering: box, zoom: 16)
        XCTAssertEqual(Array(range).count, range.count)
        XCTAssertTrue(range.contains(TileKey(containing: brandenburgGate, zoom: 16)))
        XCTAssertGreaterThanOrEqual(range.count, 9)
        let corner = GeoCoordinate(latitude: box.maxLatitude, longitude: box.maxLongitude)
        XCTAssertTrue(range.contains(TileKey(containing: corner, zoom: 16)))
    }

    func testBoundingBoxHelpers() {
        let box = GeoBoundingBox(containing: [brandenburgGate, alexanderplatz])!
        XCTAssertTrue(box.contains(brandenburgGate))
        XCTAssertTrue(box.contains(alexanderplatz))
        XCTAssertFalse(box.contains(GeoCoordinate(latitude: 53.55, longitude: 9.99)))
        let grown = box.expanded(byMeters: 100)
        XCTAssertTrue(grown.contains(GeoCoordinate(latitude: box.maxLatitude + 0.0005, longitude: box.center.longitude)))
        XCTAssertTrue(box.intersects(grown))
    }
}
