import XCTest
@testable import MapQuestCore

final class BuildingDataTests: XCTestCase {
    func testParseLength() {
        XCTAssertEqual(OSMBuildingHeights.parseLength("12"), 12)
        XCTAssertEqual(OSMBuildingHeights.parseLength("12.5 m"), 12.5)
        XCTAssertEqual(OSMBuildingHeights.parseLength("12,5"), 12.5)
        XCTAssertEqual(OSMBuildingHeights.parseLength("368m"), 368)
        XCTAssertEqual(OSMBuildingHeights.parseLength("40 ft")!, 12.192, accuracy: 1e-9)
        XCTAssertEqual(OSMBuildingHeights.parseLength("12'6\"")!, 3.81, accuracy: 1e-9)
        XCTAssertEqual(OSMBuildingHeights.parseLength("20;25"), 20)
        XCTAssertNil(OSMBuildingHeights.parseLength("tall"))
        XCTAssertNil(OSMBuildingHeights.parseLength(""))
        XCTAssertNil(OSMBuildingHeights.parseLength(nil))
    }

    func testHeightRules() {
        var h = OSMBuildingHeights.heights(tags: ["building": "yes", "height": "21"])
        XCTAssertEqual(h.height, 21); XCTAssertEqual(h.source, .tagged)
        h = OSMBuildingHeights.heights(tags: ["building": "apartments", "building:levels": "5", "roof:levels": "1"])
        XCTAssertEqual(h.height, 18); XCTAssertEqual(h.source, .levels)
        h = OSMBuildingHeights.heights(tags: ["building": "garage"])
        XCTAssertEqual(h.height, 3); XCTAssertEqual(h.source, .estimated)
        h = OSMBuildingHeights.heights(tags: ["building": "yes", "building:levels": "3", "building:min_level": "1"])
        XCTAssertEqual(h.minHeight, 3)
        h = OSMBuildingHeights.heights(tags: ["building": "roof"])
        XCTAssertGreaterThanOrEqual(h.minHeight, 2, "canopies do not block the view")
        h = OSMBuildingHeights.heights(tags: ["building": "yes", "height": "5", "min_height": "9"])
        XCTAssertEqual(h.minHeight, 0, "inconsistent min_height is dropped")
        XCTAssertFalse(OSMBuildingHeights.isBuilding(tags: ["building": "no"]))
        XCTAssertTrue(OSMBuildingHeights.isBuilding(tags: ["man_made": "tower", "height": "368"]))
        XCTAssertFalse(OSMBuildingHeights.isBuilding(tags: ["man_made": "tower"]))
    }

    func testRingAssembly() {
        let a = GeoCoordinate(latitude: 0, longitude: 0), b = GeoCoordinate(latitude: 0, longitude: 1)
        let c = GeoCoordinate(latitude: 1, longitude: 1), d = GeoCoordinate(latitude: 1, longitude: 0)
        // Two halves, the second one reversed; plus an unclosable fragment.
        let rings = RingAssembler.rings(from: [[a, b, c], [a, d, c], [b, d]])
        XCTAssertEqual(rings.count, 1)
        XCTAssertEqual(rings[0].count, 5)
        XCTAssertEqual(rings[0].first, rings[0].last)
    }

    /// Overpass `out tags geom;` output for a few buildings near Alexanderplatz.
    static let overpassFixture = """
    {"version":0.6,"elements":[
      {"type":"way","id":1001,"tags":{"building":"yes","height":"25","name":"Haus A"},
       "geometry":[{"lat":52.5200,"lon":13.4100},{"lat":52.5200,"lon":13.4105},{"lat":52.5203,"lon":13.4105},{"lat":52.5203,"lon":13.4100},{"lat":52.5200,"lon":13.4100}]},
      {"type":"way","id":1002,"tags":{"building":"apartments","building:levels":"6"},
       "geometry":[{"lat":52.5210,"lon":13.4100},{"lat":52.5210,"lon":13.4104},{"lat":52.5212,"lon":13.4104},{"lat":52.5212,"lon":13.4100},{"lat":52.5210,"lon":13.4100}]},
      {"type":"way","id":1003,"tags":{"building":"no"},
       "geometry":[{"lat":52.5220,"lon":13.4100},{"lat":52.5220,"lon":13.4101},{"lat":52.5221,"lon":13.4101},{"lat":52.5220,"lon":13.4100}]},
      {"type":"way","id":1004,"tags":{"man_made":"tower","height":"368","name":"Berliner Fernsehturm"},
       "geometry":[{"lat":52.52080,"lon":13.40930},{"lat":52.52080,"lon":13.40955},{"lat":52.52095,"lon":13.40955},{"lat":52.52095,"lon":13.40930},{"lat":52.52080,"lon":13.40930}]},
      {"type":"relation","id":77,"tags":{"type":"multipolygon","building":"office","height":"30"},
       "members":[
         {"type":"way","ref":1,"role":"outer","geometry":[{"lat":52.5180,"lon":13.4100},{"lat":52.5180,"lon":13.4120},{"lat":52.5190,"lon":13.4120}]},
         {"type":"way","ref":2,"role":"outer","geometry":[{"lat":52.5180,"lon":13.4100},{"lat":52.5190,"lon":13.4100},{"lat":52.5190,"lon":13.4120}]},
         {"type":"way","ref":3,"role":"inner","geometry":[{"lat":52.5183,"lon":13.4105},{"lat":52.5183,"lon":13.4115},{"lat":52.5187,"lon":13.4115},{"lat":52.5187,"lon":13.4105},{"lat":52.5183,"lon":13.4105}]},
         {"type":"node","ref":9,"role":"entrance"}
       ]}
    ]}
    """

    func testOverpassParser() throws {
        let buildings = try OverpassBuildingParser.buildings(from: Data(Self.overpassFixture.utf8))
        XCTAssertEqual(buildings.map(\.id).sorted(), [-(77 * 16), 1001, 1002, 1004])
        let a = try XCTUnwrap(buildings.first { $0.id == 1001 })
        XCTAssertEqual(a.height, 25)
        XCTAssertEqual(a.name, "Haus A")
        XCTAssertEqual(a.footprint.exterior.count, 4, "closing node dropped")
        XCTAssertEqual(a.footprint.areaSquareMeters, 33.9 * 33.4, accuracy: 60)
        XCTAssertEqual(buildings.first { $0.id == 1002 }?.height, 18)
        XCTAssertEqual(buildings.first { $0.id == 1004 }?.height, 368)
        let courtyardBlock = try XCTUnwrap(buildings.first { $0.id < 0 })
        XCTAssertEqual(courtyardBlock.footprint.holes.count, 1)
        XCTAssertEqual(courtyardBlock.height, 30)
    }

    func testOverpassQueryMentionsBoundingBox() {
        let query = OverpassClient.query(for: GeoBoundingBox(minLatitude: 52.5, minLongitude: 13.4, maxLatitude: 52.51, maxLongitude: 13.42))
        XCTAssertTrue(query.contains("way[\"building\"](52.500000,13.400000,52.510000,13.420000)"))
        XCTAssertTrue(query.contains("out tags geom;"))
    }

    func testCachingSourceDownloadsEachTileOnce() async throws {
        let fixture = try OverpassBuildingParser.buildings(from: Data(Self.overpassFixture.utf8))
        let counter = DownloadCounter()
        let source = CachingBuildingSource(cache: InMemoryBuildingCache(), download: { box in
            await counter.increment()
            return fixture.filter { WebMercator.boundingBox(for: $0.bounds).intersects(box) }
        })
        let rect = WebMercator.worldRect(for: GeoBoundingBox(center: GeoCoordinate(latitude: 52.5200, longitude: 13.4100), radius: 200))
        let first = try await source.buildings(in: rect)
        let second = try await source.buildings(in: rect)
        XCTAssertEqual(Set(first.map(\.id)), Set(second.map(\.id)))
        XCTAssertTrue(first.contains { $0.id == 1001 })
        let downloads = await counter.value
        XCTAssertEqual(downloads, TileRange(covering: rect, zoom: 14).count)
    }

    func testOfflineSourceReportsUnavailableData() async {
        let source = CachingBuildingSource(cache: InMemoryBuildingCache(), download: nil)
        let rect = WebMercator.worldRect(for: GeoBoundingBox(center: Walk.origin, radius: 100))
        do {
            _ = try await source.buildings(in: rect)
            XCTFail("expected an error")
        } catch let error as BuildingSourceError {
            guard case .unavailable = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }
}

actor DownloadCounter {
    var value = 0
    func increment() { value += 1 }
}
