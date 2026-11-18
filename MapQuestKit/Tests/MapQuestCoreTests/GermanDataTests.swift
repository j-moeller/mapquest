import Foundation
import XCTest
@testable import MapQuestCore

/// The Berlin data in German: every English text has its German counterpart, with
/// the same facts (IDs, years, sectors, places, stops).
final class GermanDataTests: XCTestCase {
    override func tearDown() {
        Localization.language = .en
        super.tearDown()
    }

    func testSightNames() throws {
        let sights = try TestPackages.berlin().catalog.sights
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
        let stations = try TestPackages.berlin().stations
        let main = try XCTUnwrap(stations["s:hauptbahnhof"])
        XCTAssertEqual(main.names.primary(.en), "Hauptbahnhof", "station names stay German first")
        XCTAssertEqual(main.otherName, "Central Station")
    }

    func testEntriesInGerman() throws {
        let english = try TestPackages.berlin().infos(.en)
        let german = try TestPackages.berlin().infos(.de)
        XCTAssertEqual(Set(german.entries.keys), Set(english.entries.keys))
        XCTAssertGreaterThan(german.entries.values.filter { $0.language == "de" }.count, 170)
        for (id, entry) in german.entries {
            XCTAssertFalse(entry.paragraphs.isEmpty, id)
            XCTAssertNil(entry.text.range(of: #"\[[^\]]*[ˈː][^\]]*\]"#, options: .regularExpression), "\(id): pronunciation left")
        }
    }

    func testHistoryInGerman() throws {
        let english = try TestPackages.berlin().histories(.en)
        let german = try TestPackages.berlin().histories(.de)
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
        let achievements = try TestPackages.berlin().packages.flatMap { $0.achievements ?? [] }
        // A title the same in both languages is given once (`LocalizedText` falls back to English).
        let untranslated = achievements.filter { $0.descriptions.text(in: "de") == nil }.map(\.id)
        XCTAssertTrue(untranslated.isEmpty, "no German: \(untranslated)")
        for achievement in achievements {
            guard let description = achievement.descriptions.text(in: "de") else { continue }
            XCTAssertFalse(achievement.titles(.de).isEmpty, achievement.id)
            XCTAssertGreaterThan(description.count, 15, achievement.id)
            XCTAssertNotEqual(description, achievement.descriptions.text(in: "en"), achievement.id)
        }
        Localization.language = .de
        let first = try XCTUnwrap(achievements.first { $0.id == "first-capture" })
        XCTAssertEqual(first.title, first.titles.text(in: "de"))
        XCTAssertEqual(try XCTUnwrap(achievements.first { $0.id == "all-sights" }).title, "Ich bin ein Berliner")
    }

    func testRemembranceInGerman() throws {
        let english = try TestPackages.berlin().remembrance(.en)
        let german = try TestPackages.berlin().remembrance(.de)
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
