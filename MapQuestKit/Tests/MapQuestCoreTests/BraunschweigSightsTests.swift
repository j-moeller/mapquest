import Foundation
import XCTest
@testable import MapQuestCore

/// Braunschweig's sights, entries, history, achievements and places of remembrance:
/// the same rules as Berlin's, read in Braunschweig's own history.
final class BraunschweigSightsTests: XCTestCase {
    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Braunschweig/\(name)"))
    }

    override func tearDown() {
        Localization.language = .en
        super.tearDown()
    }

    func sights() throws -> SightCatalog { try SightCatalog.decode(load("braunschweig-sights.json")) }
    func histories() throws -> SightHistoryCatalog {
        try SightHistoryCatalog.decode(load("braunschweig-sight-history.json"), city: "braunschweig")
    }

    func testSights() throws {
        let catalog = try sights()
        XCTAssertGreaterThanOrEqual(catalog.count, 50)
        let city = try GeoJSON.playArea(named: "Braunschweig", from: load("braunschweig-boundary.geojson"))
        let districts = try GeoJSON.polygonFeatures(from: load("braunschweig-districts.geojson"))
            .map { PlayArea(name: $0.properties["name"] ?? "", polygons: $0.polygons) }
        for sight in catalog.sights {
            XCTAssertTrue(city.contains(sight.coordinate), "\(sight.name) lies in Braunschweig")
            let district = try XCTUnwrap(districts.first { $0.name == sight.district }, "\(sight.name) has a district")
            XCTAssertTrue(district.contains(sight.coordinate), "\(sight.name) lies in \(district.name)")
        }
        let berlin = try CaptureTests.berlinSights()
        XCTAssertTrue(Set(catalog.sights.map(\.id)).isDisjoint(with: berlin.sights.map(\.id)), "IDs are unique across cities")
        let lion = try XCTUnwrap(catalog["burgloewe"])
        XCTAssertEqual(lion.category, .monument)
        XCTAssertEqual(lion.latitude, 52.2647, accuracy: 0.001)
        XCTAssertEqual(lion.longitude, 10.5238, accuracy: 0.001)
        XCTAssertEqual(lion.name, "Brunswick Lion")
        XCTAssertEqual(lion.otherName, "Braunschweiger Löwe")
        XCTAssertEqual(catalog["braunschweiger-dom"]?.district, "Mitte")
        XCTAssertGreaterThanOrEqual(Set(catalog.sights.map(\.category)).count, 12)
        XCTAssertGreaterThanOrEqual(Set(catalog.sights.compactMap(\.district)).count, 5)
    }

    func testEntriesInBothLanguages() throws {
        let catalog = try sights()
        let english = try SightInfoCatalog.decode(load("braunschweig-sight-info.json"))
        let german = try SightInfoCatalog.decode(load("braunschweig-sight-info-de.json"))
        let withEntry = catalog.sights.filter { english[$0.id] != nil }
        XCTAssertGreaterThanOrEqual(withEntry.count, catalog.count - 3, "nearly every sight has an entry")
        for sight in withEntry {
            let entry = try XCTUnwrap(english[sight.id])
            XCTAssertGreaterThan(entry.text.count, 40, sight.id)
            XCTAssertTrue(entry.url.absoluteString.contains("wikipedia.org"), sight.id)
            XCTAssertNotNil(german[sight.id], "\(sight.id) in German")
        }
        XCTAssertEqual(german["braunschweiger-dom"]?.title, "Braunschweiger Dom")
    }

    func testHistory() throws {
        let catalog = try sights()
        let histories = try histories()
        let german = try SightHistoryCatalog.decode(load("braunschweig-sight-history-de.json"), city: "braunschweig")
        let dated = catalog.sights.filter { histories[$0.id]?.year != nil }
        XCTAssertGreaterThan(dated.count, catalog.count / 2, "most sights are dated")
        for (id, history) in histories.entries {
            let deutsch = try XCTUnwrap(german[id], id)
            XCTAssertEqual(deutsch.year, history.year, id)
            XCTAssertEqual(deutsch.architects.count, history.architects.count, id)
        }
        // The era and ruler come from Braunschweig's history, not Berlin's.
        let cathedral = try XCTUnwrap(histories["braunschweiger-dom"])
        XCTAssertEqual(cathedral.year, 1173)
        XCTAssertEqual(cathedral.context?.era.id, "bs-welf")
        XCTAssertEqual(cathedral.context?.ruler?.name, "Henry the Lion")
        XCTAssertEqual(cathedral.commissionedBy, ["Henry the Lion"])
        XCTAssertEqual(histories["residenzschloss"]?.context?.ruler?.name, "William")
        XCTAssertEqual(histories["residenzschloss"]?.architects, ["Carl Theodor Ottmer"])
        XCTAssertEqual(histories["neues-rathaus"]?.context?.era.id, "bs-duchy")
        Localization.language = .de
        XCTAssertEqual(german["braunschweiger-dom"]?.context?.ruler?.name, "Heinrich der Löwe")
        XCTAssertEqual(german["braunschweiger-dom"]?.styles.first, "Romanik")
    }

    func testAchievements() throws {
        let catalog = try sights()
        let achievements = try Achievement.decodeList(load("braunschweig-achievements.json"))
        let book = AchievementBook(achievements: achievements, catalog: catalog, histories: try histories())
        XCTAssertEqual(Set(achievements.map(\.id)).count, achievements.count, "unique IDs")
        let berlin = try Achievement.decodeList(Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Berlin/berlin-achievements.json")))
        XCTAssertTrue(Set(achievements.map(\.id)).isDisjoint(with: berlin.map(\.id)), "IDs are unique across cities")
        XCTAssertEqual(book.skipped, [], "every achievement picks at least two sights")
        XCTAssertGreaterThanOrEqual(achievements.count, 30)
        let remembrance = Set(catalog.sights.filter(\.isPlaceOfRemembrance).map(\.id))
        for entry in book.entries {
            let achievement = entry.achievement
            XCTAssertNotNil(achievement.de, achievement.id)
            XCTAssertGreaterThan(achievement.description.count, 30, achievement.id)
            for id in entry.members { XCTAssertNotNil(catalog[id], "\(achievement.id): \(id) is a Braunschweig sight") }
            for id in (achievement.rule.sights ?? []) + (achievement.rule.include ?? []) {
                XCTAssertNotNil(catalog[id], "\(achievement.id) lists \(id)")
            }
            XCTAssertTrue(remembrance.isDisjoint(with: entry.members), "\(achievement.id) asks for no place of remembrance")
            if let era = achievement.rule.era {
                XCTAssertTrue(BraunschweigHistory.eras.contains { $0.id == era }, "\(achievement.id): \(era)")
            }
        }
        XCTAssertEqual(Set(try XCTUnwrap(book["bs-henry-the-lion"]).members),
                       ["burgloewe", "burg-dankwarderode", "braunschweiger-dom"])
        XCTAssertEqual(book["bs-all-sights"]?.target, catalog.sights.filter { !$0.isPlaceOfRemembrance }.count)
        // Berlin's achievements count only Berlin's sights, Braunschweig's only Braunschweig's.
        let (berlinBook, _, berlinCatalog) = try AchievementTests.berlinBook()
        let merged = AchievementBook.merged([berlinBook, book])
        XCTAssertEqual(merged.entries.count, berlinBook.entries.count + book.entries.count)
        XCTAssertTrue(Set(try XCTUnwrap(merged["churches"]).members).isSubset(of: berlinCatalog.sights.map(\.id)))
        XCTAssertTrue(Set(try XCTUnwrap(merged["bs-churches"]).members).isSubset(of: catalog.sights.map(\.id)))
    }

    func testRemembranceGuide() throws {
        let catalog = try sights()
        let guide = try RemembranceGuide.decode(load("braunschweig-remembrance.json"))
        let german = try RemembranceGuide.decode(load("braunschweig-remembrance-de.json"))
        let places = guide.chapters.flatMap(\.places).map(\.sight)
        let remembrance = catalog.sights.filter(\.isPlaceOfRemembrance).map(\.id)
        XCTAssertEqual(places.sorted(), remembrance.sorted(), "every place of remembrance in exactly one chapter, nothing else")
        XCTAssertEqual(german.chapters.map(\.id), guide.chapters.map(\.id))
        XCTAssertEqual(german.chapters.map { $0.places.map(\.sight) }, guide.chapters.map { $0.places.map(\.sight) })
        XCTAssertEqual(german.tours.map(\.stops), guide.tours.map(\.stops))
        for chapter in guide.chapters + german.chapters {
            XCTAssertGreaterThan(chapter.text.count, 40, chapter.id)
            XCTAssertTrue(chapter.id.hasPrefix("bs-"), "chapter IDs are unique across cities")
            for place in chapter.places { XCTAssertGreaterThan(place.remembers.count, 40, place.sight) }
        }
        for tour in guide.tours {
            let length = RemembranceGuide.length(of: tour.stops.compactMap { catalog[$0]?.coordinate })
            XCTAssertLessThan(length, 6_000, "\(tour.id) is a walk")
        }
        XCTAssertTrue(guide.remembers("magnifriedhof")?.contains("Lessing") ?? false)
    }
}
