import CoreLocation
import Foundation
import ImageIO
import MapQuestCore
import SwiftUI
import UIKit

/// The capture component (docs/02-architecture.md, "Capture"): sights of the
/// bundled cities are discovered once the fog of war around them is lifted – the
/// radius layer reaches them (their entries unlock) – and captured by
/// photographing them from where you can see them; U-Bahn and S-Bahn stations
/// are collected by going there. It only reads the discovered area of
/// the selected data source and keeps its own log and photos per data source
/// (`FileCaptureStore`), separate from the data stores.

/// What the capture animation shows: sights discovered, a sight captured (with
/// the achievements it completes), or lines of stations completed.
struct Celebration: Identifiable, Equatable {
    enum Kind: Equatable {
        case discovered, photographed, lines
    }

    let id = UUID()
    var kind: Kind = .discovered
    let sights: [Sight]
    /// Discovered or captured sights, or collected stations.
    let capturedCount: Int
    let totalCount: Int
    var achievements: [Achievement] = []
}

/// A quiet note that a place of remembrance was visited – no celebration.
struct RemembranceNotice: Identifiable, Equatable {
    let id = UUID()
    let sights: [Sight]
}

/// Stations just collected (a small notice over the map).
struct StationToast: Identifiable, Equatable {
    let id = UUID()
    let stations: [Station]
}

/// A request to show a sight or station on the 2D map.
struct SightFocus: Equatable {
    let id: Int
    let placeID: String
    let latitude: Double
    let longitude: Double
}

/// A sight as drawn on the maps.
struct SightPin: Equatable, Identifiable {
    let sight: Sight
    /// When you came near it (a question mark until discovered).
    var nearbySince: Date? = nil
    /// When it was discovered (its entry unlocked).
    let discoveredAt: Date?
    /// When it was captured (photographed).
    let capturedAt: Date?

    var id: String { sight.id }
    var isNearby: Bool { nearbySince != nil && !isDiscovered }
    var isDiscovered: Bool { discoveredAt != nil }
    var isCaptured: Bool { capturedAt != nil }
}

/// A station as drawn on the 2D map.
struct StationPin: Equatable, Identifiable {
    let station: Station
    let collectedAt: Date?

    var id: String { station.id }
    var isCollected: Bool { collectedAt != nil }
}

@MainActor
final class CaptureModel: ObservableObject {
    let catalog: SightCatalog
    /// The sights' entries (unlocked by discovering them), in the app's language.
    var infos: SightInfoCatalog { infoCatalogs[Localization.language] ?? infoCatalogs[.en] ?? SightInfoCatalog() }
    /// The sights' historical facts (unlocked with their entries), in the app's language.
    var histories: SightHistoryCatalog { historyCatalogs[Localization.language] ?? historyCatalogs[.en] ?? SightHistoryCatalog() }
    /// The entries in each language (German falls back to English sight by sight).
    private let infoCatalogs: [Language: SightInfoCatalog]
    /// The facts in each language; achievements are decided on the English ones.
    private let historyCatalogs: [Language: SightHistoryCatalog]
    /// The U-Bahn and S-Bahn stations and lines.
    let stations: StationCatalog
    /// The sights of the game: all but the places of remembrance, which are not captured.
    let gameSightCount: Int
    /// The achievements of the bundled cities, each city's resolved against its own sights and stations.
    let achievements: AchievementBook
    /// The cities with sights (Berlin, Braunschweig), in order.
    let sightCities: [City]
    /// The city of every sight and every achievement (`City.id`).
    private let cityOfSight: [String: String]
    private let cityOfAchievement: [String: String]
    private let stationCity: [String: String]
    /// The city whose sights, achievements and places of remembrance the list shows:
    /// where you are (`follow(_:)`), else the last one; kept across launches.
    @Published var cityID: String {
        didSet { UserDefaults.standard.set(cityID, forKey: Self.cityKey) }
    }
    private static let cityKey = "CaptureModel.city" // not localized
    /// Sights in cities with photorealistic 3D buildings (Apple Maps): their entries show them.
    let photorealistic3D: Set<String>
    /// The places of remembrance as a short history and as walks, outside the game, in the app's language.
    var remembrance: RemembranceGuide { remembranceGuides[Localization.language] ?? remembranceGuides[.en] ?? RemembranceGuide() }
    private let remembranceGuides: [Language: RemembranceGuide]
    @Published private(set) var log = CaptureLog()
    @Published private(set) var celebration: Celebration?
    @Published private(set) var focus: SightFocus?
    /// Which icons the maps show (menu › Map icons); kept across launches.
    @Published var iconFilter = MapIconFilter.load() {
        didSet { iconFilter.save() }
    }
    /// Stations just collected.
    @Published private(set) var stationToast: StationToast?
    /// A place of remembrance just visited.
    @Published private(set) var remembranceNotice: RemembranceNotice?
    /// Debug: photograph sights from anywhere (and from the photo library without a camera).
    @Published var photosAnywhere = false
    /// A sight whose entry should open the camera (from the discovery animation).
    @Published var cameraRequest: String?
    @Published var showsList = false {
        didSet { if !showsList { celebrateNext() } }
    }
    /// The sight whose entry is shown (from the map or the capture animation).
    @Published var entry: Sight? {
        didSet { if entry == nil { celebrateNext() } }
    }

    private var store: (any CaptureStore)?
    private var sourceID: String?
    /// Only data sources that record this device's positions celebrate captures.
    private var celebrates = false
    private var pending: [DiscoveredAreaSnapshot]?
    /// How far the radius layer may end from a sight for it to be nearby (`SightCapture.nearbyTolerance`).
    private var nearbyTolerance = SightCapture.nearbyTolerance(circleRadius: 50)
    /// The area last checked (to check again after a reset).
    private var lastSnapshots: [DiscoveredAreaSnapshot] = []
    private var isEvaluating = false
    private var focusCounter = 0
    /// Lines completed by collected stations, waiting for their celebration.
    private var lineCelebrations: [Achievement] = []

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapQuest/Captures")
    }

    init(bundle: Bundle = .main) {
        // Locals: `self` cannot be read before all its properties are set.
        let catalog = Self.loadCatalog(bundle)
        let histories = Self.loadHistories(bundle, language: .en)
        let stations = Self.loadStations(bundle)
        let catalogs = Cities.all.map { city in (city, Self.loadCatalog(bundle, cities: [city])) }.filter { !$0.1.sights.isEmpty }
        sightCities = catalogs.map { $0.0 }
        cityOfSight = Dictionary(catalogs.flatMap { city, catalog in catalog.sights.map { ($0.id, city.id) } }, uniquingKeysWith: { first, _ in first })
        let books = catalogs.map { city, cityCatalog in
            (city, AchievementBook(achievements: Self.loadAchievements(bundle, cities: [city]), catalog: cityCatalog,
                                   histories: histories, stations: stations))
        }
        cityOfAchievement = Dictionary(books.flatMap { city, book in book.entries.map { ($0.achievement.id, city.id) } },
                                       uniquingKeysWith: { first, _ in first })
        stationCity = Dictionary(Cities.all.flatMap { city in Self.loadStations(bundle, cities: [city]).stations.map { ($0.id, city.id) } },
                                 uniquingKeysWith: { first, _ in first })
        let savedCity = UserDefaults.standard.string(forKey: Self.cityKey)
        cityID = catalogs.contains { $0.0.id == savedCity } ? savedCity! : (catalogs.first?.0.id ?? "berlin") // not localized
        self.catalog = catalog
        gameSightCount = catalog.sights.filter { !$0.isPlaceOfRemembrance }.count
        let infos = Self.loadInfos(bundle, language: .en)
        infoCatalogs = [.en: infos, .de: .merged([Self.loadInfos(bundle, language: .de), infos])]
        historyCatalogs = [.en: histories, .de: .merged([Self.loadHistories(bundle, language: .de), histories])]
        self.stations = stations
        achievements = .merged(books.map { $0.1 })
        photorealistic3D = Set(Cities.all.filter(\.hasPhotorealistic3D).flatMap { city in
            Self.loadCatalog(bundle, cities: [city]).sights.map(\.id)
        })
        let english = Self.loadRemembrance(bundle, language: .en)
        let german = Self.loadRemembrance(bundle, language: .de)
        remembranceGuides = [.en: english, .de: german.chapters.isEmpty ? english : german]
    }

    /// A city's data file in a language: `<city>-<name>.json` in English, `<city>-<name>-de.json` in German.
    static func data(_ bundle: Bundle, city: City, _ name: String, language: Language) -> Data? {
        let suffix = language == .en ? "" : "-\(language.rawValue)"
        guard let url = bundle.url(forResource: "\(city.id)-\(name)\(suffix)", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The remembrance guides of all bundled cities (`<city>-remembrance[-de].json`).
    static func loadRemembrance(_ bundle: Bundle, language: Language) -> RemembranceGuide {
        .merged(Cities.all.compactMap { city -> RemembranceGuide? in
            data(bundle, city: city, "remembrance", language: language).flatMap { try? RemembranceGuide.decode($0) }
        })
    }

    /// The sight entries of all bundled cities (`<city>-sight-info[-de].json`).
    static func loadInfos(_ bundle: Bundle, language: Language) -> SightInfoCatalog {
        .merged(Cities.all.compactMap { city -> SightInfoCatalog? in
            data(bundle, city: city, "sight-info", language: language).flatMap { try? SightInfoCatalog.decode($0) }
        })
    }

    /// The historical facts of all bundled cities (`<city>-sight-history[-de].json`), each read in its city's history.
    static func loadHistories(_ bundle: Bundle, language: Language) -> SightHistoryCatalog {
        .merged(Cities.all.compactMap { city -> SightHistoryCatalog? in
            data(bundle, city: city, "sight-history", language: language).flatMap { try? SightHistoryCatalog.decode($0, city: city.id) }
        })
    }

    /// The stations and lines of the bundled cities (`<city>-stations.json`).
    static func loadStations(_ bundle: Bundle, cities: [City] = Cities.all) -> StationCatalog {
        .merged(cities.compactMap { city -> StationCatalog? in
            guard let url = bundle.url(forResource: "\(city.id)-stations", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? StationCatalog.decode(data)
        })
    }

    /// The achievements of the bundled cities (`<city>-achievements.json`).
    static func loadAchievements(_ bundle: Bundle, cities: [City] = Cities.all) -> [Achievement] {
        cities.flatMap { city -> [Achievement] in
            guard let url = bundle.url(forResource: "\(city.id)-achievements", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return [] }
            return (try? Achievement.decodeList(data)) ?? []
        }
    }

    /// The sight lists of the bundled cities (`<city>-sights.json`).
    static func loadCatalog(_ bundle: Bundle, cities: [City] = Cities.all) -> SightCatalog {
        .merged(cities.compactMap { city -> SightCatalog? in
            guard let url = bundle.url(forResource: "\(city.id)-sights", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? SightCatalog.decode(data)
        })
    }

    // MARK: Inputs

    /// Checks sights and stations against where you have been: the radius layer
    /// (all time) of a data source, with circles of `circleRadius` metres around your positions.
    func update(sourceID: String, recordsLocations: Bool, snapshots: [DiscoveredAreaSnapshot], circleRadius: Double) {
        if sourceID != self.sourceID {
            switchSource(to: sourceID, recordsLocations: recordsLocations)
        }
        nearbyTolerance = SightCapture.nearbyTolerance(circleRadius: circleRadius)
        pending = snapshots
        lastSnapshots = snapshots
        evaluateIfIdle()
    }

    /// Set per data source once the sights discovered only by the line of sight (for a
    /// while sights counted once seen) were undone; captured ones stay.
    private static func lineOfSightUndoneKey(_ sourceID: String) -> String {
        "CaptureModel.lineOfSightDiscoveriesUndone." + sourceID // not localized
    }

    /// Forgets the captures of the selected data source and checks all sights again.
    func resetCaptures() {
        guard let sourceID else { return }
        reset(sourceID: sourceID)
        pending = lastSnapshots
        evaluateIfIdle()
    }

    /// Forgets the captures (and photos) of a data source whose discovered area was deleted.
    func reset(sourceID: String) {
        try? FileManager.default.removeItem(at: Self.photoDirectory(for: sourceID))
        guard sourceID == self.sourceID else {
            try? FileCaptureStore(directory: Self.directory, sourceID: sourceID).delete()
            return
        }
        try? store?.delete()
        log = CaptureLog()
        celebration = nil
        remembranceNotice = nil
        lineCelebrations = []
        stationToast = nil
    }

    private func switchSource(to sourceID: String, recordsLocations: Bool) {
        self.sourceID = sourceID
        celebrates = recordsLocations
        let store = FileCaptureStore(directory: Self.directory, sourceID: sourceID)
        self.store = store
        log = (try? store.load()) ?? CaptureLog()
        celebration = nil
        remembranceNotice = nil
        pending = nil
        celebrateNext()
    }

    private func evaluateIfIdle() {
        guard !isEvaluating, let snapshots = pending, let sourceID else { return }
        pending = nil
        isEvaluating = true
        let base = log
        let sights = catalog.sights
        let stationList = self.stations.stations
        let celebrate = celebrates
        // Once, with the radius layer loaded: undo discoveries it does not reach.
        let undoKey = Self.lineOfSightUndoneKey(sourceID)
        let undoesLineOfSight = !UserDefaults.standard.bool(forKey: undoKey) && snapshots.contains { $0.pieceCount > 0 }
        let nearbyTolerance = self.nearbyTolerance
        Task { [weak self] in
            let (forgotten, nearby, added, collected) = await Task.detached(priority: .utility) {
                () -> ([String], [String: Date], [CaptureRecord], [CaptureRecord]) in
                var updated = base
                let forgotten = undoesLineOfSight
                    ? SightCapture.forgetUnreached(&updated, sights: sights, snapshots: snapshots) : []
                let added = SightCapture.update(&updated, sights: sights, snapshots: snapshots, celebrate: celebrate)
                let marked = SightCapture.updateNearby(&updated, sights: sights, snapshots: snapshots, tolerance: nearbyTolerance)
                let nearby = Dictionary(uniqueKeysWithValues: marked.compactMap { id in updated.nearby[id].map { (id, $0) } })
                let collected = StationCapture.update(&updated, stations: stationList, snapshots: snapshots)
                return (forgotten, nearby, added, collected)
            }.value
            guard let self else { return }
            self.isEvaluating = false
            if self.sourceID == sourceID, undoesLineOfSight {
                for id in forgotten where !self.log.isCaptured(id) {
                    self.log.records[id] = nil
                }
                if !forgotten.isEmpty { self.persist() }
                UserDefaults.standard.set(true, forKey: undoKey)
            }
            // Sights you came near: question marks on the map.
            if self.sourceID == sourceID, !nearby.isEmpty {
                self.log.nearby.merge(nearby) { old, _ in old }
                if added.isEmpty && collected.isEmpty { self.persist() }
            }
            if self.sourceID == sourceID, !added.isEmpty || !collected.isEmpty {
                for record in added where self.log.records[record.sightID] == nil {
                    self.log.records[record.sightID] = record
                }
                let new = collected.filter { self.log.stations[$0.sightID] == nil }
                for record in new {
                    self.log.stations[record.sightID] = record
                }
                self.persist()
                if celebrate, !new.isEmpty {
                    self.announce(stations: new.map(\.sightID))
                }
                self.celebrateNext()
            }
            self.evaluateIfIdle()
        }
    }

    /// A notice for collected stations; a celebration for the lines they complete.
    private func announce(stations ids: [String]) {
        let collected = ids.compactMap { stations[$0] }
        guard !collected.isEmpty else { return }
        stationToast = StationToast(stations: collected)
        let toast = stationToast?.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self?.stationToast?.id == toast { self?.stationToast = nil }
        }
        let unlocked = achievements.unlocked(by: ids, captured: Set(log.captureDates.keys))
            .filter { $0.rule.isAboutStations }
        lineCelebrations.append(contentsOf: unlocked)
    }

    private func persist() {
        try? store?.save(log)
    }

    // MARK: Celebration

    /// Shows the next capture: one at a time, or all together when more than three wait
    /// (e.g. the first check of discoveries made before).
    private func celebrateNext() {
        // Not behind the list or an entry: after they close.
        guard celebration == nil, remembranceNotice == nil, celebrates, entry == nil, !showsList else { return }
        // Places of remembrance are not celebrated: a quiet note, all of them at once.
        let remembered = log.uncelebrated.filter { catalog[$0.sightID]?.isPlaceOfRemembrance ?? false }
        if !remembered.isEmpty {
            remembranceNotice = RemembranceNotice(sights: remembered.compactMap { catalog[$0.sightID] })
            return
        }
        if !lineCelebrations.isEmpty {
            celebration = Celebration(kind: .lines, sights: [], capturedCount: log.stations.count, totalCount: stations.count,
                                      achievements: lineCelebrations)
            lineCelebrations = []
            return
        }
        let waiting = log.uncelebrated
        guard let first = waiting.first else { return }
        let shown = waiting.count > 3 ? waiting : [first]
        let sights = shown.compactMap { catalog[$0.sightID] }
        guard !sights.isEmpty else {
            log.markCelebrated(shown.map(\.sightID))
            persist()
            return
        }
        // Discovering unlocks the entries; achievements count captures (photos). Counts of the first sight's city.
        let city = city(of: sights[0].id)
        celebration = Celebration(kind: .discovered, sights: sights, capturedCount: discoveredCount(in: city),
                                  totalCount: gameSightCount(in: city))
    }

    /// The note on a place of remembrance was read or closed.
    func finishRemembranceNotice() {
        guard let remembranceNotice else { return }
        log.markCelebrated(remembranceNotice.sights.map(\.id))
        persist()
        self.remembranceNotice = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.celebrateNext()
        }
    }

    /// The animation ended or was tapped away.
    func finishCelebration() {
        guard let celebration else { return }
        if celebration.kind == .discovered {
            log.markCelebrated(celebration.sights.map(\.id))
            persist()
        }
        self.celebration = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.celebrateNext()
        }
    }

    // MARK: Views

    /// Photographed sights.
    var capturedCount: Int { log.photos.count }
    /// Visited sights of the game (entries unlocked); places of remembrance do not count.
    var discoveredCount: Int {
        log.records.keys.filter { !(catalog[$0]?.isPlaceOfRemembrance ?? false) }.count
    }
    var collectedStationCount: Int { log.stations.count }

    /// Progress of every achievement.
    var achievementProgress: [AchievementProgress] { achievements.progress(log) }

    // MARK: Cities

    /// The city of a sight or achievement (`City.id`).
    func city(of id: String) -> String? { cityOfSight[id] ?? cityOfAchievement[id] }

    /// The city the list shows.
    var currentCity: City? { sightCities.first { $0.id == cityID } }

    /// The city of a station: the one whose stations file it came from (only Berlin has any).
    func city(ofStation station: Station) -> String? { stationCity[station.id] }

    /// Follows where you are: the list switches to the city you are in (elsewhere it stays).
    func follow(_ cityID: String?) {
        guard let cityID, cityID != self.cityID, sightCities.contains(where: { $0.id == cityID }) else { return }
        self.cityID = cityID
    }

    /// The sights of a city (all cities with `nil`).
    func sights(in city: String?) -> [Sight] {
        guard let city else { return catalog.sights }
        return catalog.sights.filter { cityOfSight[$0.id] == city }
    }

    /// The sights of the game in a city: places of remembrance do not count.
    func gameSightCount(in city: String?) -> Int { sights(in: city).filter { !$0.isPlaceOfRemembrance }.count }
    /// Photographed sights in a city.
    func capturedCount(in city: String?) -> Int { log.photos.keys.filter { city == nil || cityOfSight[$0] == city }.count }
    /// Discovered sights of the game in a city.
    func discoveredCount(in city: String?) -> Int {
        log.records.keys.filter { (city == nil || cityOfSight[$0] == city) && !(catalog[$0]?.isPlaceOfRemembrance ?? false) }.count
    }
    /// Progress of the achievements of a city.
    func achievementProgress(in city: String?) -> [AchievementProgress] {
        achievementProgress.filter { city == nil || cityOfAchievement[$0.id] == city }
    }
    /// The places of remembrance of a city, as chapters and walks.
    func remembrance(in city: String?) -> RemembranceGuide {
        guard let city else { return remembrance }
        let guide = remembrance
        return RemembranceGuide(
            chapters: guide.chapters.filter { $0.places.contains { cityOfSight[$0.sight] == city } },
            tours: guide.tours.filter { $0.stops.contains { cityOfSight[$0] == city } }
        )
    }

    /// Progress of the achievements a sight counts towards (milestones aside).
    func achievementProgress(containing sight: Sight) -> [AchievementProgress] {
        let dates = log.captureDates
        return achievements.entries
            .filter { !$0.achievement.rule.isMilestone && $0.members.contains(sight.id) }
            .map { achievements.progress(of: $0, captured: dates) }
    }

    /// The nearest station of an achievement not collected yet (without a position, the first).
    func nextStation(in progress: AchievementProgress, from location: CLLocation?) -> Station? {
        let open = progress.members.filter { !progress.captured.contains($0) }.compactMap { stations[$0] }
        guard let location else { return open.first }
        return open.min { a, b in
            location.distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
                < location.distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
    }

    /// The sight to go for next in an achievement: the nearest one not captured yet
    /// (without a position, the first in its list).
    func nextSight(in progress: AchievementProgress, from location: CLLocation?) -> Sight? {
        let open = progress.members.filter { !progress.captured.contains($0) }.compactMap { catalog[$0] }
        guard let location else { return open.first }
        return open.min { a, b in
            location.distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
                < location.distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
    }

    /// Pins for the maps: sights you came near (a question mark) or discovered, and the
    /// others too when `showingAll`. Places of remembrance are always shown (quietly):
    /// they are not hidden as a prize. Without what `iconFilter` hides – except the
    /// sight shown on the map on request.
    func pins(showingAll: Bool) -> [SightPin] {
        catalog.sights.compactMap { sight in
            let record = log.records[sight.id]
            let nearby = log.nearby[sight.id]
            guard record != nil || nearby != nil || showingAll || sight.isPlaceOfRemembrance else { return nil }
            let pin = SightPin(sight: sight, nearbySince: sight.isPlaceOfRemembrance ? nil : nearby,
                               discoveredAt: record?.capturedAt, capturedAt: log.photos[sight.id]?.capturedAt)
            return iconFilter.shows(pin) || focus?.placeID == sight.id ? pin : nil
        }
    }

    /// Sights you came near but have not discovered yet (question marks on the map).
    var nearbyCount: Int { catalog.sights.filter { log.isNearby($0.id) }.count }

    /// Station pins: collected stations, and the others too when `showingAll`.
    func stationPins(showingAll: Bool) -> [StationPin] {
        stations.stations.compactMap { station in
            let record = log.stations[station.id]
            guard record != nil || showingAll,
                  iconFilter.shows(station) || focus?.placeID == station.id else { return nil }
            return StationPin(station: station, collectedAt: record?.capturedAt)
        }
    }

    /// Shows a sight on the 2D map (closes the list and any entry).
    func show(_ sight: Sight) {
        focusOn(id: sight.id, latitude: sight.latitude, longitude: sight.longitude)
    }

    /// Shows a station on the 2D map.
    func show(_ station: Station) {
        focusOn(id: station.id, latitude: station.latitude, longitude: station.longitude)
    }

    private func focusOn(id: String, latitude: Double, longitude: Double) {
        focusCounter += 1
        focus = SightFocus(id: focusCounter, placeID: id, latitude: latitude, longitude: longitude)
        showsList = false
        entry = nil
    }

    /// Opens a sight's entry with the camera (from the discovery animation).
    func photograph(_ sight: Sight) {
        cameraRequest = sight.id
        entry = sight
    }

    // MARK: Photo captures

    /// How far beyond its extent a sight may be photographed from, in metres.
    static let photoReach: CLLocationDistance = 150

    /// The folder of a data source's capture photos.
    nonisolated static func photoDirectory(for sourceID: String) -> URL {
        let safe = sourceID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("Photos").appendingPathComponent(safe) // not localized
    }

    /// Whether new photos are also saved to the Photos app (menu › Photos; on by default).
    nonisolated static let savesToPhotosKey = "CaptureModel.savesToPhotos" // not localized
    nonisolated static var savesToPhotos: Bool {
        UserDefaults.standard.object(forKey: savesToPhotosKey) as? Bool ?? true
    }

    /// All photos taken with the selected data source, newest first.
    var allPhotos: [TakenPhoto] { log.album.sorted { $0.takenAt > $1.takenAt } }

    /// The file of a photo.
    func url(of photo: TakenPhoto) -> URL? {
        sourceID.map { Self.photoDirectory(for: $0).appendingPathComponent(photo.fileName) }
    }

    private let thumbnails = NSCache<NSString, UIImage>()

    /// A photo made small (`maxPixels` on its longer side) for galleries; read off the main thread and kept.
    func thumbnail(of photo: TakenPhoto, maxPixels: Int) async -> UIImage? {
        guard let url = url(of: photo) else { return nil }
        let key = "\(photo.fileName)@\(maxPixels)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }

    /// A data source's capture log: the selected one's from memory, others' from their file.
    func log(for sourceID: String) -> CaptureLog? {
        if sourceID == self.sourceID { return log }
        return try? FileCaptureStore(directory: Self.directory, sourceID: sourceID).load()
    }

    /// Replaces a data source's photos with an export's (`DataArchive`).
    nonisolated static func restorePhotos(from reader: DataArchive.Reader, sourceID: String) throws {
        let folder = photoDirectory(for: sourceID)
        try? FileManager.default.removeItem(at: folder)
        try reader.restorePhotos(to: folder)
    }

    /// Takes over an imported capture log for a data source (after `restorePhotos`).
    func adopt(_ imported: CaptureLog?, sourceID: String) {
        let restored = imported ?? CaptureLog()
        try? FileCaptureStore(directory: Self.directory, sourceID: sourceID).save(restored)
        thumbnails.removeAllObjects()
        guard sourceID == self.sourceID else { return }
        log = restored
        celebration = nil
        remembranceNotice = nil
        lineCelebrations = []
        stationToast = nil
        pending = lastSnapshots
        evaluateIfIdle()
    }

    /// Deletes a photo; the sight stays captured.
    func deletePhoto(_ photo: TakenPhoto) {
        if let url = url(of: photo) { try? FileManager.default.removeItem(at: url) }
        log.removePhoto(photo)
        persist()
    }

    /// A photo at full size.
    func image(of photo: TakenPhoto) -> UIImage? {
        url(of: photo).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// How far the position is from the sight (`nil` without a recent position).
    func distance(to sight: Sight, from location: CLLocation?) -> CLLocationDistance? {
        guard let location, location.horizontalAccuracy >= 0, location.timestamp.timeIntervalSinceNow > -300 else { return nil }
        return location.distance(from: CLLocation(latitude: sight.latitude, longitude: sight.longitude))
    }

    /// Whether the camera may open for a sight: when it is in view from where you are
    /// (`view`: what the line of sight showed from your latest evaluated position, if
    /// that was near here and recent), or within `photoReach` of it.
    func canPhotograph(_ sight: Sight, from location: CLLocation?, view: LineOfSightView?) -> Bool {
        // Places of remembrance are not captured.
        guard celebrates, !sight.isPlaceOfRemembrance, log.isDiscovered(sight.id) else { return false }
        if photosAnywhere { return true }
        if let view, let location, Self.isCurrent(view, at: location), view.shows(sight) { return true }
        guard let meters = distance(to: sight, from: location) else { return false }
        return meters <= sight.radius + Self.photoReach
    }

    /// A view counts for the camera while you are still near where it was seen from (25 m, two minutes).
    static func isCurrent(_ view: LineOfSightView, at location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0, location.timestamp.timeIntervalSince(view.sample.timestamp) < 120 else { return false }
        let seenFrom = CLLocation(latitude: view.sample.latitude, longitude: view.sample.longitude)
        return location.distance(from: seenFrom) <= 25
    }

    /// Keeps a photo of a sight – every photo is kept; the first captures the sight –
    /// and, when switched on in the menu, saves it to the Photos app as well (camera
    /// photos only: one picked from the library is there already).
    /// Returns the celebration of a first capture, with the achievements it completes.
    func saveCapture(_ image: UIImage, of sight: Sight, at location: CLLocation?, fromCamera: Bool = true) throws -> Celebration? {
        guard let sourceID else { return nil }
        let directory = Self.photoDirectory(for: sourceID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        // One file per photo: the sight and when it was taken.
        let stamp = String(Int64((now.timeIntervalSince1970 * 1000).rounded()))
        let fileName = sight.id.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined() + "-" + stamp + ".jpg" // not localized
        guard let data = Self.scaled(image, maxSide: 2048).jpegData(compressionQuality: 0.85) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        let first = log.addPhoto(TakenPhoto(
            sightID: sight.id, takenAt: now,
            latitude: location?.coordinate.latitude, longitude: location?.coordinate.longitude, fileName: fileName
        ))
        persist()
        if fromCamera && Self.savesToPhotos {
            PhotoLibrary.save(image, location: location, date: now)
        }
        guard first else { return nil }
        let unlocked = achievements.unlocked(by: [sight.id], captured: Set(log.captureDates.keys))
        let city = city(of: sight.id)
        return Celebration(kind: .photographed, sights: [sight], capturedCount: capturedCount(in: city), totalCount: gameSightCount(in: city),
                           achievements: unlocked)
    }

    private static func scaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return image }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Opens a sight's entry over the map.
    func openEntry(_ sight: Sight) {
        entry = sight
    }

    /// Whether the sight's entry shows photorealistic 3D buildings (else its photo).
    func hasPhotorealistic3D(_ sight: Sight) -> Bool {
        photorealistic3D.contains(sight.id)
    }

    /// Discovered sights whose entry has not been opened yet (not places of
    /// remembrance: their entries are open to all, nothing is "new" about them).
    func hasUnreadEntry(_ sight: Sight) -> Bool {
        !sight.isPlaceOfRemembrance && log.hasUnreadEntry(sight.id)
    }

    var unreadEntryCount: Int {
        log.records.keys.filter { !log.readEntries.contains($0) && !(catalog[$0]?.isPlaceOfRemembrance ?? false) }.count
    }

    /// The entry was opened.
    func markRead(_ sight: Sight) {
        guard log.hasUnreadEntry(sight.id) else { return }
        log.readEntries.insert(sight.id)
        persist()
    }
}

extension Notification.Name {
    /// Posted by the app model with the data source ID when its discovered area was deleted.
    static let discoveredDataDeleted = Notification.Name("MapQuest.discoveredDataDeleted")
}

/// Icons and names of the sight categories.
extension SightCategory {
    var symbol: String {
        switch self {
        case .landmark: return "star.fill"
        case .museum: return "building.columns.fill"
        case .palace: return "crown.fill"
        case .church: return "bell.fill"
        case .viewpoint: return "binoculars.fill"
        case .memorial: return "rectangle.portrait.fill"
        case .park: return "tree.fill"
        case .square: return "square.grid.2x2.fill"
        case .culture: return "theatermasks.fill"
        case .monument: return "flag.fill"
        case .zoo: return "pawprint.fill"
        case .bridge: return "water.waves"
        case .stadium: return "sportscourt.fill"
        case .fountain: return "drop.fill"
        case .market: return "basket.fill"
        case .government: return "building.2.fill"
        case .cemetery: return "rectangle.portrait.fill"
        case .club: return "headphones"
        }
    }

    var title: String {
        switch self {
        case .landmark: return tr("Landmark")
        case .museum: return tr("Museum")
        case .palace: return tr("Palace")
        case .church: return tr("Church")
        case .viewpoint: return tr("Viewpoint")
        case .memorial: return tr("Place of remembrance")
        case .park: return tr("Park")
        case .square: return tr("Square")
        case .culture: return tr("Culture")
        case .monument: return tr("Monument")
        case .zoo: return tr("Zoo")
        case .bridge: return tr("Bridge")
        case .stadium: return tr("Stadium or arena")
        case .fountain: return tr("Fountain")
        case .market: return tr("Market")
        case .government: return tr("Seat of government")
        case .cemetery: return tr("Cemetery")
        case .club: return tr("Club")
        }
    }

    /// The title inside a phrase ("Undiscovered church"): lower case in English;
    /// German nouns keep their capital.
    var titleInPhrase: String {
        Localization.language == .en ? title.lowercased() : title
    }
}

/// The capture colour; and the quiet stone grey of places of remembrance.
extension Color {
    static let captureGold = Color(red: 1.0, green: 0.76, blue: 0.18)
    static let remembrance = Color(red: 0.42, green: 0.45, blue: 0.49)
    /// Sights you came near: a question mark in violet.
    static let nearbySight = Color(red: 0.45, green: 0.36, blue: 0.95)
}

extension UIColor {
    static let captureGold = UIColor(red: 1.0, green: 0.76, blue: 0.18, alpha: 1)
    static let remembrance = UIColor(red: 0.42, green: 0.45, blue: 0.49, alpha: 1)
    static let nearbySight = UIColor(red: 0.45, green: 0.36, blue: 0.95, alpha: 1)
}
