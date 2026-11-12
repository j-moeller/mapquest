import Foundation
import XCTest
@testable import MapQuestCore

/// The Berlin data in German: every English text has its German counterpart, with
/// the same facts (IDs, years, sectors, places, stops).
final class GermanDataTests: XCTestCase {
    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Berlin/\(name)"))
    }

    override func tearDown() {
        Localization.language = .en
        super.tearDown()
    }

    func testSightNames() throws {
        let sights = try SightCatalog.decode(load("berlin-sights.json")).sights
        let english = sights.filter { $0.englishName != nil }
        XCTAssertGreaterThan(english.count, 100)
        for sight in english {
            XCTAssertNotEqual(sight.englishName, sight.germanName, sight.id)
            XCTAssertFalse(sight.englishName?.isEmpty ?? true, sight.id)
        }
        let gate = try XCTUnwrap(sights.first { $0.id == "brandenburger-tor" })
        XCTAssertEqual(gate.name, "Brandenburg Gate")
        XCTAssertEqual(gate.otherName, "Brandenburger Tor")
        let square = try XCTUnwrap(sights.first { $0.id == "alexanderplatz" })
        XCTAssertNil(square.otherName, "German names used in English stay alone")
        let stations = try StationCatalog.decode(load("berlin-stations.json"))
        let main = try XCTUnwrap(stations["s:hauptbahnhof"])
        XCTAssertEqual(main.names.primary(.en), "Hauptbahnhof", "station names stay German first")
        XCTAssertEqual(main.otherName, "Central Station")
    }

    func testEntriesInGerman() throws {
        let english = try SightInfoCatalog.decode(load("berlin-sight-info.json"))
        let german = try SightInfoCatalog.decode(load("berlin-sight-info-de.json"))
        XCTAssertEqual(Set(german.entries.keys), Set(english.entries.keys))
        XCTAssertGreaterThan(german.entries.values.filter { $0.language == "de" }.count, 170)
        for (id, entry) in german.entries {
            XCTAssertFalse(entry.paragraphs.isEmpty, id)
            XCTAssertNil(entry.text.range(of: #"\[[^\]]*[ˈː][^\]]*\]"#, options: .regularExpression), "\(id): pronunciation left")
        }
    }

    func testHistoryInGerman() throws {
        let english = try SightHistoryCatalog.decode(load("berlin-sight-history.json"))
        let german = try SightHistoryCatalog.decode(load("berlin-sight-history-de.json"))
        XCTAssertEqual(Set(german.entries.keys), Set(english.entries.keys))
        let englishWords = #"\b(rebuilt|built|laid out|named|founded|since|from|until|moved|extended|renovated|the|of|and|c\.)\b"#
        for (id, facts) in german.entries {
            let source = try XCTUnwrap(english[id])
            XCTAssertEqual(facts.year, source.year, id)
            XCTAssertEqual(facts.sector, source.sector, id)
            XCTAssertEqual(facts.styles.count, source.styles.count, id)
            XCTAssertEqual(facts.architects.count, source.architects.count, id)
            XCTAssertEqual(facts.commissionedBy.count, source.commissionedBy.count, id)
            for phrase in [facts.built, facts.opened].compactMap({ $0 }) + facts.styles {
                XCTAssertNil(phrase.range(of: englishWords, options: [.regularExpression, .caseInsensitive]),
                             "\(id): English left in “\(phrase)”")
            }
        }
        XCTAssertGreaterThan(german.entries.values.filter { $0.history != nil }.count, 100)
        Localization.language = .de
        XCTAssertEqual(german["brandenburger-tor"]?.builtPhrase, "Erbaut 1788–1791")
        XCTAssertEqual(german["brandenburger-tor"]?.styles, ["Klassizismus"])
    }

    func testAchievementsInGerman() throws {
        let achievements = try Achievement.decodeList(load("berlin-achievements.json"))
        let untranslated = achievements.filter { $0.de == nil }.map(\.id)
        XCTAssertTrue(untranslated.isEmpty, "no German: \(untranslated)")
        for achievement in achievements {
            guard let de = achievement.de else { continue }
            XCTAssertFalse(de.title.isEmpty, achievement.id)
            XCTAssertGreaterThan(de.description.count, 15, achievement.id)
            XCTAssertNotEqual(de.description, achievement.englishDescription, achievement.id)
        }
        Localization.language = .de
        let first = try XCTUnwrap(achievements.first { $0.id == "first-capture" })
        XCTAssertEqual(first.title, first.de?.title)
    }

    func testRemembranceInGerman() throws {
        let english = try RemembranceGuide.decode(load("berlin-remembrance.json"))
        let german = try RemembranceGuide.decode(load("berlin-remembrance-de.json"))
        XCTAssertEqual(german.chapters.map(\.id), english.chapters.map(\.id))
        for (de, en) in zip(german.chapters, english.chapters) {
            XCTAssertEqual(de.places.map(\.sight), en.places.map(\.sight), de.id)
            XCTAssertNotEqual(de.text, en.text, de.id)
            for (place, source) in zip(de.places, en.places) {
                XCTAssertNotEqual(place.remembers, source.remembers, place.sight)
                XCTAssertGreaterThan(place.remembers.count, 40, place.sight)
            }
        }
        XCTAssertEqual(german.tours.map(\.id), english.tours.map(\.id))
        XCTAssertEqual(german.tours.map(\.stops), english.tours.map(\.stops))
    }
}
