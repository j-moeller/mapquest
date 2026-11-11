import XCTest
@testable import MapQuestCore

final class CaptureTests: XCTestCase {
    static func berlinSights() throws -> SightCatalog {
        try SightCatalog.decode(Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Berlin/berlin-sights.json")))
    }

    /// A square piece of discovered area, `half` metres from its centre to each side.
    func piece(around coordinate: GeoCoordinate, half: Double, discovered: Date) -> DiscoveredPiece {
        let center = WebMercator.project(coordinate)
        let h = Int64(half / WebMercator.metersPerUnit(atWorldY: Double(center.y)))
        let polygon = WorldPolygon(exterior: [
            WorldPoint(x: center.x - h, y: center.y - h), WorldPoint(x: center.x + h, y: center.y - h),
            WorldPoint(x: center.x + h, y: center.y + h), WorldPoint(x: center.x - h, y: center.y + h),
        ])
        return DiscoveredPiece(
            layer: "test", regionID: UUID(), tile: TileKey(containing: center, zoom: DiscoveryGrid.zoom),
            polygon: polygon, areaSquareMeters: 4 * half * half, firstDiscovered: discovered, lastUpdated: discovered
        )
    }

    func snapshot(_ pieces: [DiscoveredPiece]) -> DiscoveredAreaSnapshot {
        DiscoveredAreaSnapshot(layer: "test", piecesByTile: Dictionary(grouping: pieces, by: \.tile), maximumMarginUnits: 0)
    }

    /// Moves a coordinate east by `meters`.
    func east(_ c: GeoCoordinate, _ meters: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: c.latitude, longitude: c.longitude + meters / (111_320 * cos(c.latitude * .pi / 180)))
    }

    func testBundledBerlinSights() throws {
        let catalog = try Self.berlinSights()
        XCTAssertEqual(catalog.count, 119)
        let berlin = try GeoJSON.playArea(named: "Berlin", from: Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Berlin/berlin-boundary.geojson")))
        for sight in catalog.sights {
            XCTAssertTrue(berlin.contains(sight.coordinate), "\(sight.name) lies in Berlin")
            XCTAssertTrue((30...150).contains(sight.radius), sight.name)
            XCTAssertFalse(sight.name.isEmpty)
        }
        let gate = try XCTUnwrap(catalog["brandenburger-tor"])
        XCTAssertEqual(gate.category, .monument)
        XCTAssertEqual(gate.latitude, 52.5163, accuracy: 0.001)
        XCTAssertEqual(gate.longitude, 13.3777, accuracy: 0.001)
        XCTAssertEqual(Set(catalog.sights.map(\.category)).count, SightCategory.allCases.count, "every category is used")
    }

    func testCaptureRule() throws {
        let sight = Sight(id: "s", name: "S", category: .monument, latitude: 52.5163, longitude: 13.3777, radius: 40)
        XCTAssertEqual(sight.captureTolerance, 0, "small sights must be covered")
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        // Discovered area ending 10 m before the sight: not captured (it must be covered).
        let near = piece(around: east(sight.coordinate, 30), half: 20, discovered: early)
        XCTAssertNil(SightCapture.captureDate(of: sight, in: [snapshot([near])]))
        // Covering it: captured; the earliest covering piece gives the date.
        let on = piece(around: east(sight.coordinate, 15), half: 20, discovered: late)
        let onEarlier = piece(around: sight.coordinate, half: 10, discovered: early)
        XCTAssertEqual(SightCapture.captureDate(of: sight, in: [snapshot([near, on])]), late)
        XCTAssertEqual(SightCapture.captureDate(of: sight, in: [snapshot([on]), snapshot([onEarlier])]), early)
        XCTAssertNil(SightCapture.captureDate(of: sight, in: [snapshot([])]))

        // A large open area (150 m): reached within 100 m of its position.
        let field = Sight(id: "f", name: "F", category: .park, latitude: 52.4733, longitude: 13.4019, radius: 150)
        XCTAssertEqual(field.captureTolerance, 100)
        let inside = piece(around: east(field.coordinate, 100), half: 20, discovered: late)  // edge at 80 m
        XCTAssertEqual(SightCapture.captureDate(of: field, in: [snapshot([inside])]), late)
        let outside = piece(around: east(field.coordinate, 140), half: 20, discovered: late)  // edge at 120 m
        XCTAssertNil(SightCapture.captureDate(of: field, in: [snapshot([outside])]))
    }

    func testLogUpdateCelebrationAndStore() throws {
        let sights = [
            Sight(id: "a", name: "A", category: .museum, latitude: 52.52, longitude: 13.40),
            Sight(id: "b", name: "B", category: .church, latitude: 52.53, longitude: 13.41),
        ]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let area = snapshot([piece(around: sights[0].coordinate, half: 30, discovered: date)])
        var log = CaptureLog()
        let added = SightCapture.update(&log, sights: sights, snapshots: [area], now: date)
        XCTAssertEqual(added.map(\.sightID), ["a"])
        XCTAssertEqual(log.uncelebrated.map(\.sightID), ["a"])
        XCTAssertTrue(SightCapture.update(&log, sights: sights, snapshots: [area]).isEmpty, "captured once")
        log.markCelebrated(["a"])
        XCTAssertTrue(log.uncelebrated.isEmpty)

        // View-only sources: recorded as celebrated.
        var other = CaptureLog()
        SightCapture.update(&other, sights: sights, snapshots: [area], celebrate: false)
        XCTAssertTrue(other.uncelebrated.isEmpty)
        XCTAssertTrue(other.isCaptured("a"))

        // Captures stay when the area shrinks (another rebuild).
        SightCapture.update(&log, sights: sights, snapshots: [snapshot([])])
        XCTAssertTrue(log.isCaptured("a"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("captures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCaptureStore(directory: directory, sourceID: "local/own profile")
        XCTAssertEqual(store.url.lastPathComponent, "local_own_profile.json")
        XCTAssertEqual(try store.load(), CaptureLog(), "empty without a file")
        try store.save(log)
        XCTAssertEqual(try store.load(), log)
        try store.delete()
        XCTAssertEqual(try store.load(), CaptureLog())

        // Logs made under the first (looser) rule are discarded once.
        var old = log
        old.version = 1
        try store.save(old)
        XCTAssertEqual(try store.load(), CaptureLog())
        XCTAssertEqual(CaptureLog().version, CaptureLog.currentVersion)
    }

    /// End to end with the radius layer (50 m circles): a position at the
    /// Brandenburger Tor captures it; one 80 m east of it does not (the circle
    /// ends 30 m before the gate); the Reichstag 250 m away is never captured.
    func testAPositionCapturesTheSightThere() async throws {
        let catalog = try Self.berlinSights()
        let gate = try XCTUnwrap(catalog["brandenburger-tor"])

        func captures(at coordinate: GeoCoordinate) async throws -> CaptureLog {
            let store = InMemoryDataStore()
            let engine = DiscoveryEngine(model: CircleDiscoveryModel(), store: store)
            let recorder = LocationRecorder(store: store, engines: [engine])
            let sample = LocationSample(
                latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 36,
                horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
            )
            _ = try await recorder.record(sample)
            try await recorder.finishSampling()
            var log = CaptureLog()
            SightCapture.update(&log, sights: catalog.sights, snapshots: [await engine.snapshot()])
            return log
        }

        let there = try await captures(at: gate.coordinate)
        XCTAssertTrue(there.isCaptured("brandenburger-tor"))
        XCTAssertFalse(there.isCaptured("reichstag"))
        XCTAssertFalse(there.isCaptured("fernsehturm"))
        let nearby = try await captures(at: east(gate.coordinate, 80))
        XCTAssertFalse(nearby.isCaptured("brandenburger-tor"))
    }
}

final class SightInfoTests: XCTestCase {
    func testBundledBerlinEntries() throws {
        let sights = try CaptureTests.berlinSights()
        let infos = try SightInfoCatalog.decode(Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Berlin/berlin-sight-info.json")))
        XCTAssertEqual(infos.entries.count, sights.count, "every sight has an entry")
        for (id, info) in infos.entries {
            XCTAssertNotNil(sights[id], "\(id) is a sight")
            XCTAssertFalse(info.paragraphs.isEmpty, id)
            XCTAssertLessThanOrEqual(info.text.count, 2_000, id)
            XCTAssertFalse(info.text.contains("pronounced"), "\(id): pronunciation removed")
            XCTAssertFalse(info.text.contains("()"), "\(id): no empty parentheses")
            XCTAssertTrue(info.url.host?.hasSuffix("wikipedia.org") ?? false, id)
            XCTAssertTrue(["en", "de"].contains(info.language), id)
            if let photo = info.image {
                XCTAssertTrue(photo.url.host?.hasSuffix("wikimedia.org") ?? false, id)
                XCTAssertEqual(photo.page.host, "commons.wikimedia.org", id)
                XCTAssertFalse(photo.license.isEmpty, id)
                let file = photo.page.lastPathComponent.lowercased()
                XCTAssertFalse(file.hasSuffix(".svg") || file.contains("logo"), "\(id): a photo, not a logo or drawing")
            }
        }
        let gate = try XCTUnwrap(infos["brandenburger-tor"])
        XCTAssertEqual(gate.title, "Brandenburg Gate")
        XCTAssertTrue(gate.text.contains("18th-century"))
        XCTAssertNotNil(gate.image)
        XCTAssertGreaterThanOrEqual(infos.entries.values.filter { $0.image != nil }.count, 110, "nearly all entries have a photo")
    }

    func testReadEntriesAndOlderLogs() throws {
        var log = CaptureLog()
        log.records["a"] = CaptureRecord(sightID: "a", capturedAt: Date(), recordedAt: Date(), celebrated: true)
        XCTAssertTrue(log.hasUnreadEntry("a"))
        XCTAssertFalse(log.hasUnreadEntry("b"), "not captured: locked, not unread")
        log.readEntries.insert("a")
        XCTAssertFalse(log.hasUnreadEntry("a"))

        // A version-2 log written before entries existed (no readEntries) still loads.
        let json = #"{"version":2,"records":{"a":{"sightID":"a","capturedAt":"2026-11-10T10:00:00Z","recordedAt":"2026-11-10T10:00:00Z","celebrated":true}}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(CaptureLog.self, from: Data(json.utf8))
        XCTAssertTrue(old.isCaptured("a"))
        XCTAssertTrue(old.readEntries.isEmpty)
    }
}

final class SightHistoryTests: XCTestCase {
    func testErasAndRulers() throws {
        func ruler(_ year: Int, _ sector: BerlinSector? = nil) -> String? { BerlinHistory.ruler(in: year, sector: sector)?.name }
        func era(_ year: Int, _ sector: BerlinSector? = nil) -> String? { BerlinHistory.era(in: year, sector: sector)?.id }

        XCTAssertNil(BerlinHistory.context(in: 1100), "before Brandenburg")
        XCTAssertEqual(era(1230), "margraviate")
        XCTAssertEqual(ruler(1230), "Ascanian margraves")
        XCTAssertEqual(ruler(1542), "Joachim II Hector")
        XCTAssertEqual(ruler(1695), "Frederick III")
        XCTAssertEqual(era(1701), "prussia")
        XCTAssertEqual(ruler(1786), "Frederick II, the Great", "succession in August: July counts")
        XCTAssertEqual(ruler(1788), "Frederick William II")
        XCTAssertEqual(ruler(1866), "William I")
        XCTAssertEqual(era(1884), "empire")
        XCTAssertEqual(ruler(1888), "Wilhelm II")
        XCTAssertEqual(era(1918), "empire", "the revolution came in November")
        XCTAssertEqual(ruler(1919), "Friedrich Ebert")
        XCTAssertEqual(ruler(1932), "Paul von Hindenburg")
        XCTAssertEqual(ruler(1936), "Adolf Hitler")
        XCTAssertEqual(era(1945), "occupation")
        XCTAssertEqual(era(1949, .east), "occupation", "the GDR was founded in October")

        XCTAssertEqual(era(1965), "divided", "no sector: the divided city")
        XCTAssertNil(ruler(1965))
        XCTAssertEqual(era(1965, .east), "east")
        XCTAssertEqual(ruler(1965, .east), "Walter Ulbricht")
        XCTAssertEqual(ruler(1965, .west), "Ludwig Erhard")
        XCTAssertEqual(ruler(1987, .east), "Erich Honecker")
        XCTAssertEqual(ruler(1987, .west), "Helmut Kohl")
        XCTAssertEqual(ruler(1990, .east), "Lothar de Maizière", "reunification came in October")
        XCTAssertEqual(era(1991, .east), "reunified")
        XCTAssertEqual(ruler(2005), "Gerhard Schröder")
        XCTAssertEqual(ruler(2013, .west), "Angela Merkel", "the sector does not matter after 1990")
        XCTAssertEqual(ruler(2026), "Friedrich Merz")

        // Every era but the undivided fallback has rulers, all rulers have eras, in order.
        let ids = Set(BerlinHistory.eras.map(\.id))
        XCTAssertEqual(ids.count, BerlinHistory.eras.count)
        for ruler in BerlinHistory.rulers {
            XCTAssertTrue(ids.contains(ruler.era), ruler.name)
            let era = try XCTUnwrap(BerlinHistory.eras.first { $0.id == ruler.era })
            XCTAssertGreaterThanOrEqual(ruler.start, era.start - 1, "\(ruler.name) rules in \(era.name)")
        }
        for era in BerlinHistory.eras where era.id != "divided" {
            let rulers = BerlinHistory.rulers.filter { $0.era == era.id }
            XCTAssertFalse(rulers.isEmpty, era.name)
            XCTAssertEqual(rulers.map(\.start), rulers.map(\.start).sorted(), era.name)
        }
        XCTAssertLessThan(BerlinHistory.order(of: try XCTUnwrap(BerlinHistory.era(in: 1800))),
                          BerlinHistory.order(of: try XCTUnwrap(BerlinHistory.era(in: 1900))))
    }

    func testBundledBerlinHistory() throws {
        let sights = try CaptureTests.berlinSights()
        let catalog = try SightHistoryCatalog.decode(Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Berlin/berlin-sight-history.json")))
        XCTAssertEqual(catalog.entries.count, sights.count, "every sight has its history")
        for (id, history) in catalog.entries {
            XCTAssertNotNil(sights[id], "\(id) is a sight")
            let year = try XCTUnwrap(history.year, id)
            XCTAssertTrue((1157...2026).contains(year), id)
            XCTAssertNotNil(history.built, id)
            XCTAssertNotNil(history.sector, id)
            XCTAssertNotNil(history.context?.ruler, "\(id): a ruler in \(year)")
            for paragraph in history.historyParagraphs {
                for markup in ["{{", "}}", "[[", "]]", "<ref", "()", "''"] {
                    XCTAssertFalse(paragraph.contains(markup), "\(id): no \(markup) in the history")
                }
            }
            XCTAssertLessThanOrEqual(history.history?.count ?? 0, 1_900, id)
            for name in history.styles + history.architects + history.commissionedBy {
                XCTAssertFalse(name.trimmingCharacters(in: .whitespaces).isEmpty, id)
            }
        }
        XCTAssertGreaterThanOrEqual(catalog.entries.values.filter { $0.history != nil }.count, 75)
        XCTAssertGreaterThanOrEqual(catalog.entries.values.filter { !$0.architects.isEmpty }.count, 95)

        let gate = try XCTUnwrap(catalog["brandenburger-tor"])
        XCTAssertEqual(gate.year, 1788)
        XCTAssertEqual(gate.built, "1788–1791")
        XCTAssertEqual(gate.styles, ["Neoclassicism"])
        XCTAssertTrue(gate.architects.contains("Carl Gotthard Langhans"))
        XCTAssertEqual(gate.context?.era.name, "Kingdom of Prussia")
        XCTAssertEqual(gate.context?.ruler?.name, "Frederick William II")
        XCTAssertEqual(gate.sectorDuringDivision, .east)
        XCTAssertEqual(gate.epoch, "Built 1788–1791 · Kingdom of Prussia")
        XCTAssertEqual(catalog["bebelplatz"]?.builtPhrase, "Laid out from 1741")
        XCTAssertEqual(catalog["marienkirche"]?.builtPhrase?.hasPrefix("Built c. 1270"), true)
        XCTAssertEqual(catalog["fernsehturm"]?.epoch, "Built 1965–1969 · East Berlin (GDR)")
        XCTAssertEqual(catalog["fernsehturm"]?.context?.ruler?.name, "Walter Ulbricht")
        XCTAssertEqual(catalog["philharmonie"]?.context?.ruler?.name, "Konrad Adenauer")
        XCTAssertEqual(catalog["hufeisensiedlung"]?.sector, .west)
        XCTAssertEqual(catalog["checkpoint-charlie"]?.sector, .west)
        XCTAssertNil(catalog["humboldt-forum"]?.sectorDuringDivision, "built after 1990")
    }

    func testDecodesSparseEntries() throws {
        let json = #"{"entries":{"a":{"year":1900,"sector":"west"},"b":{}}}"#
        let catalog = try SightHistoryCatalog.decode(Data(json.utf8))
        XCTAssertEqual(catalog["a"]?.context?.ruler?.name, "Wilhelm II")
        XCTAssertEqual(catalog["b"]?.styles, [])
        XCTAssertNil(catalog["b"]?.context)
        let merged = SightHistoryCatalog.merged([catalog, SightHistoryCatalog(entries: ["a": SightHistory(year: 2000), "c": SightHistory()])])
        XCTAssertEqual(merged["a"]?.year, 1900, "the first catalog wins")
        XCTAssertNotNil(merged["c"])
    }
}
