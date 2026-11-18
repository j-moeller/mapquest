import Foundation
import XCTest
@testable import MapQuestCore

/// Sight packages (docs/09-sight-packages.md): the file format, how packages that
/// overlap resolve, scopes, declared categories, the store – and MapQuest's own.
final class SightPackageTests: XCTestCase {
    override func tearDown() {
        Localization.language = .en
        super.tearDown()
    }

    // MARK: Helpers

    private func sight(_ id: String, _ name: String, _ category: SightCategory = .church, wikidata: String? = nil,
                       sameAs: [String]? = nil, year: Int? = nil, latitude: Double = 52.5) -> SightPackage.PackageSight {
        SightPackage.PackageSight(id: id, name: name, category: category, latitude: latitude, longitude: 13.4,
                                  wikidata: wikidata, sameAs: sameAs,
                                  facts: year.map { SightPackage.Facts(year: $0, localized: ["en": .init(built: "\($0)")]) })
    }

    private func achievement(_ id: String, _ rule: AchievementRule) -> Achievement {
        Achievement(id: id, group: .collections, title: LocalizedText(en: id), description: "", symbol: "star", rule: rule)
    }

    private func pkg(_ id: String, version: String = "1", sights: [SightPackage.PackageSight] = [],
                         achievements: [Achievement] = [], includes: [String]? = nil, categories: [CategoryDefinition]? = nil,
                         region: String = "town") -> SightPackage {
        SightPackage(id: id, version: version, title: LocalizedText(en: id), language: "de",
                     region: .init(id: region, name: LocalizedText(en: region.capitalized)), includes: includes,
                     categories: categories, sights: sights, achievements: achievements)
    }

    // MARK: File format

    func testFileRoundTripsOneOrSeveralPackages() throws {
        let one = pkg("a", sights: [sight("x", "X")])
        let single = try SightPackageFile.encode([one])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: single) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "mapquest-sights")
        XCTAssertEqual(object["id"] as? String, "a", "a single package is the document itself")
        XCTAssertEqual(try SightPackageFile.decode(single), [one])

        let two = [one, pkg("b", version: "2.0", includes: ["a"])]
        let bundle = try SightPackageFile.encode(two)
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: bundle) as? [String: Any])?["packages"])
        XCTAssertEqual(try SightPackageFile.decode(bundle), two)
    }

    func testRejectsWhatIsNoPackage() throws {
        XCTAssertThrowsError(try SightPackageFile.decode(Data("{\"id\": \"a\"}".utf8))) {
            XCTAssertEqual($0 as? SightPackageFile.FileError, .notASightPackage)
        }
        XCTAssertThrowsError(try SightPackageFile.decode(Data("[1, 2]".utf8)))
        XCTAssertThrowsError(try SightPackageFile.decode(Data(#"{"format": "mapquest-sights", "formatVersion": 7, "id": "a", "version": "1", "title": "A"}"#.utf8))) {
            XCTAssertEqual($0 as? SightPackageFile.FileError, .newerFormat(7))
        }
        // A sight without a position: where it is missing is named.
        let missing = #"{"format": "mapquest-sights", "id": "a", "version": "1", "title": "A", "sights": [{"id": "x", "name": "X", "category": "church", "latitude": 52}]}"#
        XCTAssertThrowsError(try SightPackageFile.decode(Data(missing.utf8))) { error in
            guard case .unreadable(let detail)? = error as? SightPackageFile.FileError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("sights[0]") && detail.contains("longitude"), detail)
        }
        let twice = pkg("a", sights: [sight("x", "X"), sight("x", "Y")])
        XCTAssertThrowsError(try SightPackageFile.decode(SightPackageFile.encode([twice]))) {
            XCTAssertEqual($0 as? SightPackageFile.FileError, .invalid(["sight x twice"]))
        }
    }

    func testTextsInOneOrMoreLanguages() throws {
        let plain = try JSONDecoder().decode(LocalizedText.self, from: Data(#""Berliner Dom""#.utf8))
        XCTAssertEqual(plain(.en), "Berliner Dom")
        XCTAssertEqual(plain(.de), "Berliner Dom")
        let both = try JSONDecoder().decode(LocalizedText.self, from: Data(#"{"en": "Cathedral", "de": "Dom"}"#.utf8))
        XCTAssertEqual(both(.de), "Dom")
        let english = LocalizedText(en: "Cathedral")
        XCTAssertEqual(english(.de), "Cathedral", "English where there is no German")
        XCTAssertEqual(LocalizedText(["fr": "Cathédrale"])(.de), "Cathédrale", "any language before none")
        XCTAssertEqual(try JSONEncoder().encode(plain), Data(#""Berliner Dom""#.utf8))
    }

    func testVersionsCompareByParts() {
        XCTAssertTrue(SightPackage.isVersion("2026.11.18", newerThan: "2026.9.30"))
        XCTAssertTrue(SightPackage.isVersion("1.10", newerThan: "1.9"))
        XCTAssertTrue(SightPackage.isVersion("1.0.1", newerThan: "1.0"))
        XCTAssertFalse(SightPackage.isVersion("1.0", newerThan: "1.0"))
        XCTAssertFalse(SightPackage.isVersion("1.2", newerThan: "1.10"))
    }

    func testUnknownAchievementGroupsAndMissingSymbols() throws {
        let json = #"{"id": "x", "group": "pilgrimages", "title": "X", "rule": {"count": 1}}"#
        let achievement = try JSONDecoder().decode(Achievement.self, from: Data(json.utf8))
        XCTAssertEqual(achievement.group, .stories)
        XCTAssertEqual(achievement.symbol, "star.fill")
        XCTAssertEqual(achievement.description, "")
    }

    // MARK: Resolution

    func testTheNewestDescriptionOfASightWins() throws {
        let old = pkg("a", version: "2025.1.1", sights: [sight("dom", "Alter Dom")])
        let new = pkg("b", version: "2026.1.1", sights: [sight("dom", "Neuer Dom"), sight("kirche", "Kirche")])
        let library = SightLibrary(packages: [old, new])
        XCTAssertEqual(library.catalog.count, 2, "the same ID is the same place")
        XCTAssertEqual(library.catalog["dom"]?.germanName, "Neuer Dom")
        XCTAssertEqual(library.packagesOfSight["dom"], ["b", "a"])
        XCTAssertEqual(library.issues, [])

        // Of one package only the newest version counts.
        let library2 = SightLibrary(packages: [pkg("a", version: "1.9", sights: [sight("x", "Old")]),
                                               pkg("a", version: "1.10", sights: [sight("x", "New")])])
        XCTAssertEqual(library2.packages.count, 1)
        XCTAssertEqual(library2.catalog["x"]?.germanName, "New")
    }

    func testTheSamePlaceUnderAnotherID() throws {
        let city = pkg("city", version: "2", sights: [sight("dom", "Dom", wikidata: "Q1"), sight("tor", "Tor", .monument),
                                                          sight("markt", "Markt", .market)])
        let walk = pkg("walk", sights: [sight("walk.dom", "Dom", wikidata: "q1"), sight("walk.tor", "Tor", .monument, sameAs: ["tor"]),
                                            sight("walk.brunnen", "Brunnen", .fountain)],
                           achievements: [achievement("walk.all", AchievementRule(sights: ["walk.dom", "walk.tor", "walk.brunnen"]))])
        let library = SightLibrary(packages: [walk, city])
        XCTAssertEqual(library.catalog.sights.map(\.id).sorted(), ["dom", "markt", "tor", "walk.brunnen"])
        XCTAssertEqual(library.aliases, ["walk.dom": "dom", "walk.tor": "tor"])
        XCTAssertEqual(library.canonical("walk.dom"), "dom")
        XCTAssertEqual(Set(library.packagesOfSight["dom"] ?? []), ["city", "walk"])
        XCTAssertEqual(Set(library.issues.map(\.kind)), [.merged(sight: "walk.dom", into: "dom"), .merged(sight: "walk.tor", into: "tor")])
        // The walk's achievement counts the city's sights: one capture counts for both packages.
        XCTAssertEqual(Set(try XCTUnwrap(library.achievements["walk.all"]).members), ["dom", "tor", "walk.brunnen"])
    }

    func testAchievementsPickFromTheirPackageAndWhatItIncludes() throws {
        let churches = pkg("town.churches", sights: [sight("a", "A"), sight("b", "B")],
                               achievements: [achievement("churches", AchievementRule(categories: [.church]))])
        let other = pkg("village", sights: [sight("c", "C"), sight("d", "D")], region: "village")
        let town = pkg("town", sights: [sight("e", "E", .museum), sight("f", "F", .museum)],
                           achievements: [achievement("all", AchievementRule(all: true)),
                                          achievement("all-churches", AchievementRule(categories: [.church])),
                                          achievement("lonely", AchievementRule(sights: ["e", "c"]))],
                           includes: ["town.churches", "town.walks"])
        let library = SightLibrary(packages: [churches, other, town])
        XCTAssertEqual(library.scope(of: "town.churches"), ["a", "b"])
        XCTAssertEqual(library.scope(of: "town"), ["a", "b", "e", "f"])
        XCTAssertEqual(Set(try XCTUnwrap(library.achievements["churches"]).members), ["a", "b"], "not the village's churches")
        XCTAssertEqual(Set(try XCTUnwrap(library.achievements["all-churches"]).members), ["a", "b"])
        XCTAssertEqual(library.achievements["all"]?.target, 4, "everything the town includes")
        XCTAssertNil(library.achievements["lonely"], "c is not in the town's scope")
        XCTAssertEqual(Set(library.issues(of: "town").map(\.kind)), [
            .missingInclude("town.walks"), .unknownPlace(place: "c", in: "lonely"), .skippedAchievement("lonely"),
        ])
        XCTAssertEqual(library.regionOfSight["c"], "village")
        XCTAssertEqual(library.regionOfAchievement["churches"], "town")
        XCTAssertEqual(library.regions.map(\.id).sorted(), ["town", "village"])
        let village = try XCTUnwrap(library.regions.first { $0.id == "village" }?.bounds, "bounds from its sights")
        XCTAssertEqual(village.south, 52.5)
    }

    func testDeclaredCategoriesLieUnderCoreOnes() throws {
        let categories = [
            CategoryDefinition(id: "chapel", title: LocalizedText(en: "Chapel", de: "Kapelle"), parent: .church),
            CategoryDefinition(id: "wayside-chapel", title: LocalizedText(en: "Wayside chapel"), parent: "chapel", symbol: "signpost.right"),
            CategoryDefinition(id: "war-grave", title: LocalizedText(en: "War grave"), parent: .cemetery),
            CategoryDefinition(id: "church", title: "Not allowed", parent: .museum),
        ]
        let hierarchy = CategoryHierarchy(categories)
        XCTAssertEqual(hierarchy.ancestry(of: "wayside-chapel"), ["wayside-chapel", "chapel", .church])
        XCTAssertEqual(hierarchy.core(of: "wayside-chapel"), .church)
        XCTAssertEqual(hierarchy.core(of: "lighthouse"), .landmark, "unknown categories show as landmarks")
        XCTAssertTrue(hierarchy.isRemembrance("war-grave"), "inherited from the cemetery")
        XCTAssertNil(hierarchy.definitions[.church], "the core vocabulary cannot be redefined")
        XCTAssertTrue(hierarchy.matches("chapel", any: [.church]))
        XCTAssertFalse(hierarchy.matches(.church, any: ["chapel"]))

        let package = pkg("p", sights: [sight("k", "Kirche"), sight("c1", "Kapelle 1", "chapel"), sight("c2", "Kapelle 2", "wayside-chapel"),
                                             sight("g", "Grab", "war-grave"), sight("l", "Leuchtturm", "lighthouse")],
                              achievements: [achievement("churches", AchievementRule(categories: [.church])),
                                             achievement("chapels", AchievementRule(categories: ["chapel"]))],
                              categories: categories)
        let library = SightLibrary(packages: [package])
        XCTAssertEqual(Set(try XCTUnwrap(library.achievements["churches"]).members), ["k", "c1", "c2"], "chapels are churches")
        XCTAssertEqual(Set(try XCTUnwrap(library.achievements["chapels"]).members), ["c1", "c2"])
        XCTAssertEqual(library.catalog["g"]?.isPlaceOfRemembrance, true, "outside the game")
        XCTAssertEqual(library.issues.map(\.kind), [.unknownCategory(category: "lighthouse", sight: "l")])
    }

    func testFactsAreDatedInTheirChronicle() throws {
        let berlin = try TestPackages.chronicle("berlin")
        var package = pkg("p", sights: [sight("s", "S", year: 1789), sight("t", "T", year: 1789)])
        package.sights?[1].chronicle = "atlantis"
        package.chronicles = [berlin]
        let library = SightLibrary(packages: [package])
        XCTAssertEqual(library.histories(.en)["s"]?.context?.ruler?.name, "Frederick William II")
        XCTAssertNil(library.histories(.en)["t"]?.context)
        XCTAssertEqual(library.issues.map(\.kind), [.unknownChronicle(chronicle: "atlantis", sight: "t")])
    }

    // MARK: Store

    func testStoreInstallsUpdatesAndRemoves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("packages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SightPackageStore(directory: directory)
        XCTAssertEqual(store.installed().packages, [])

        let v1 = pkg("a", version: "1.0", sights: [sight("x", "X")])
        XCTAssertEqual(try store.install([v1, pkg("b/c")]).map(\.outcome), [.installed, .installed])
        XCTAssertEqual(store.url(of: "b/c").lastPathComponent, "b_c.sights.json")
        XCTAssertEqual(try store.install([v1]).map(\.outcome), [.reinstalled])
        let v2 = pkg("a", version: "1.1", sights: [sight("x", "X2")])
        XCTAssertEqual(try store.install([v2]).map(\.outcome), [.updated(from: "1.0")])
        XCTAssertEqual(try store.install([v1]).map(\.outcome), [.keptNewer(installed: "1.1")])
        XCTAssertEqual(store.installed().packages.first { $0.id == "a" }?.version, "1.1")
        XCTAssertEqual(try store.install([v1], allowingOlder: true).map(\.outcome), [.updated(from: "1.1")])

        try Data("{}".utf8).write(to: directory.appendingPathComponent("broken.sights.json"))
        let installed = store.installed()
        XCTAssertEqual(installed.packages.map(\.id).sorted(), ["a", "b/c"])
        XCTAssertEqual(installed.unreadable, ["broken.sights.json"])
        try store.remove("a")
        XCTAssertEqual(store.installed().packages.map(\.id), ["b/c"])
    }

    // MARK: MapQuest's packages

    func testMapQuestPackagesResolveWithoutIssues() throws {
        let library = try TestPackages.library("berlin", "braunschweig")
        XCTAssertEqual(library.issues, [], "\(library.issues)")
        XCTAssertEqual(library.packages.map(\.id).sorted(), [
            "mapquest.berlin", "mapquest.berlin.churches", "mapquest.berlin.remembrance", "mapquest.berlin.transit",
            "mapquest.braunschweig", "mapquest.braunschweig.churches", "mapquest.braunschweig.remembrance",
        ])
        XCTAssertEqual(library.catalog.count, 184 + 55)
        XCTAssertEqual(library.regions.map(\.id), ["berlin", "braunschweig"])
        XCTAssertEqual(library.catalog.sights.filter { library.regionOfSight[$0.id] == "braunschweig" }.count, 55)
        XCTAssertEqual(library.achievements.entries.count, 102 + 33)
        XCTAssertEqual(library.achievements.skipped, [])
        for package in library.packages {
            XCTAssertFalse(package.title(.de).isEmpty, package.id)
            XCTAssertFalse(package.summary?(.en).isEmpty ?? true, package.id)
            XCTAssertNotNil(package.region?.bounds, package.id)
        }
        let berlin = try XCTUnwrap(library.regions.first?.bounds)
        XCTAssertTrue(berlin.contains(GeoCoordinate(latitude: 52.5163, longitude: 13.3777)))
        XCTAssertFalse(berlin.contains(GeoCoordinate(latitude: 52.2647, longitude: 10.5238)))
        // The city package counts everything it includes; the churches package only churches.
        XCTAssertEqual(library.scope(of: "mapquest.berlin.churches").count, 13)
        XCTAssertTrue(library.scope(of: "mapquest.berlin").isSuperset(of: library.scope(of: "mapquest.berlin.churches")))
        XCTAssertEqual(library.achievements["all-sights"]?.target, 166, "every Berlin sight but the 18 places of remembrance")
        XCTAssertEqual(library.achievements["bs-all-sights"]?.target, 51)
        XCTAssertTrue(Set(library.achievements["churches"]?.members ?? []).isSubset(of: library.scope(of: "mapquest.berlin.churches")))
    }

    func testEachPartStandsAlone() throws {
        let parts = TestPackages.directory.appendingPathComponent("parts")
        let churches = try SightPackageFile.decode(Data(contentsOf: parts.appendingPathComponent("mapquest.berlin.churches.sights.json")))
        let library = SightLibrary(packages: churches)
        XCTAssertEqual(library.issues, [])
        XCTAssertEqual(library.catalog.count, 13)
        XCTAssertEqual(library.achievements["churches"]?.members.count, 13)
        XCTAssertEqual(library.histories(.en)["marienkirche"]?.context?.era.id, "margraviate", "with its chronicle")
        XCTAssertEqual(library.infos(.de)["berliner-dom"]?.language, "de")

        let remembrance = SightLibrary(packages: try SightPackageFile.decode(
            Data(contentsOf: parts.appendingPathComponent("mapquest.braunschweig.remembrance.sights.json"))))
        XCTAssertEqual(remembrance.issues, [])
        XCTAssertEqual(remembrance.remembrance(.de).chapters.flatMap(\.places).count, 4)
        XCTAssertTrue(remembrance.catalog.sights.allSatisfy(\.isPlaceOfRemembrance))

        // Without the parts, the city package still resolves: it names what is missing.
        let city = try TestPackages.packages("berlin").filter { $0.id == "mapquest.berlin" }
        let alone = SightLibrary(packages: city)
        XCTAssertEqual(Set(alone.issues.compactMap { issue -> String? in
            if case .missingInclude(let id) = issue.kind { return id }
            return nil
        }), ["mapquest.berlin.churches", "mapquest.berlin.remembrance", "mapquest.berlin.transit"])
        XCTAssertEqual(alone.catalog.count, 153)
    }

    func testThirdPartyPackageOverlapsBerlin() throws {
        let file = TestPackages.directory.appendingPathComponent("examples/example.berlin.fountain-walk.sights.json")
        let example = try SightPackageFile.decode(Data(contentsOf: file))
        let library = SightLibrary(packages: try TestPackages.packages("berlin") + example)
        XCTAssertEqual(library.catalog.count, 184, "the fountains are Berlin's")
        XCTAssertEqual(library.aliases, ["example.neptune": "neptunbrunnen", "example.spindler": "spindlerbrunnen",
                                         "example.friendship": "brunnen-voelkerfreundschaft"])
        XCTAssertEqual(Set(library.achievements["example.fountain-walk"]?.members ?? []),
                       ["neptunbrunnen", "spindlerbrunnen", "brunnen-voelkerfreundschaft"])
        XCTAssertEqual(library.achievements["fountains"]?.members.count, 7, "Berlin's own achievement is unchanged")
        XCTAssertEqual(library.categories.core(of: "monumental-fountain"), .fountain)
        XCTAssertEqual(library.regions.map(\.id), ["berlin"])
        XCTAssertTrue(library.issues.allSatisfy { if case .merged = $0.kind { return true } else { return false } }, "\(library.issues)")
        // On its own it is a small package with its own three sights.
        let alone = SightLibrary(packages: example)
        XCTAssertEqual(alone.issues, [])
        XCTAssertEqual(alone.catalog.count, 3)
        XCTAssertEqual(alone.achievements["example.fountain-walk"]?.members.count, 3)
    }
}
