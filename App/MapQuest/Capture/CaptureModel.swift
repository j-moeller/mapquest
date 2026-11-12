import CoreLocation
import Foundation
import MapQuestCore
import SwiftUI
import UIKit

/// The capture component (docs/02-architecture.md, "Capture"): sights of the
/// bundled cities are discovered once the fog of war around them is lifted (their
/// entries unlock) and captured by photographing them there; U-Bahn and S-Bahn
/// stations are collected by going there. It only reads the discovered area of
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
    /// When it was discovered (its entry unlocked).
    let discoveredAt: Date?
    /// When it was captured (photographed).
    let capturedAt: Date?

    var id: String { sight.id }
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
    /// The sights' entries (unlocked by capturing them).
    let infos: SightInfoCatalog
    /// The sights' historical facts (unlocked with their entries).
    let histories: SightHistoryCatalog
    /// The U-Bahn and S-Bahn stations and lines.
    let stations: StationCatalog
    /// The sights of the game: all but the places of remembrance, which are not captured.
    let gameSightCount: Int
    /// The achievements of the bundled cities, resolved against their sights and stations.
    let achievements: AchievementBook
    /// Sights in cities with photorealistic 3D buildings (Apple Maps): their entries show them.
    let photorealistic3D: Set<String>
    @Published private(set) var log = CaptureLog()
    @Published private(set) var celebration: Celebration?
    @Published private(set) var focus: SightFocus?
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
    /// The area last checked (to check again after a reset).
    private var lastSnapshots: [DiscoveredAreaSnapshot] = []
    private var isEvaluating = false
    private var focusCounter = 0
    /// Lines completed by collected stations, waiting for their celebration.
    private var lineCelebrations: [Achievement] = []

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapQuest/Captures")
    }

    init(bundle: Bundle = .main) {
        // Locals: `self` cannot be read before all its properties are set.
        let catalog = Self.loadCatalog(bundle)
        let histories = Self.loadHistories(bundle)
        let stations = Self.loadStations(bundle)
        self.catalog = catalog
        gameSightCount = catalog.sights.filter { !$0.isPlaceOfRemembrance }.count
        infos = Self.loadInfos(bundle)
        self.histories = histories
        self.stations = stations
        achievements = AchievementBook(achievements: Self.loadAchievements(bundle), catalog: catalog, histories: histories,
                                       stations: stations)
        photorealistic3D = Set(Cities.all.filter(\.hasPhotorealistic3D).flatMap { city in
            Self.loadCatalog(bundle, cities: [city]).sights.map(\.id)
        })
    }

    /// The sight entries of all bundled cities (`<city>-sight-info.json`).
    static func loadInfos(_ bundle: Bundle) -> SightInfoCatalog {
        .merged(Cities.all.compactMap { city -> SightInfoCatalog? in
            guard let url = bundle.url(forResource: "\(city.id)-sight-info", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? SightInfoCatalog.decode(data)
        })
    }

    /// The historical facts of all bundled cities (`<city>-sight-history.json`).
    static func loadHistories(_ bundle: Bundle) -> SightHistoryCatalog {
        .merged(Cities.all.compactMap { city -> SightHistoryCatalog? in
            guard let url = bundle.url(forResource: "\(city.id)-sight-history", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? SightHistoryCatalog.decode(data)
        })
    }

    /// The stations and lines of all bundled cities (`<city>-stations.json`).
    static func loadStations(_ bundle: Bundle) -> StationCatalog {
        .merged(Cities.all.compactMap { city -> StationCatalog? in
            guard let url = bundle.url(forResource: "\(city.id)-stations", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? StationCatalog.decode(data)
        })
    }

    /// The achievements of all bundled cities (`<city>-achievements.json`).
    static func loadAchievements(_ bundle: Bundle) -> [Achievement] {
        Cities.all.flatMap { city -> [Achievement] in
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

    /// Checks the sights against the discovered area (all layers, all time) of a data source.
    func update(sourceID: String, recordsLocations: Bool, snapshots: [DiscoveredAreaSnapshot]) {
        if sourceID != self.sourceID {
            switchSource(to: sourceID, recordsLocations: recordsLocations)
        }
        pending = snapshots
        lastSnapshots = snapshots
        evaluateIfIdle()
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
        Task { [weak self] in
            let (added, collected) = await Task.detached(priority: .utility) { () -> ([CaptureRecord], [CaptureRecord]) in
                var updated = base
                let added = SightCapture.update(&updated, sights: sights, snapshots: snapshots, celebrate: celebrate)
                let collected = StationCapture.update(&updated, stations: stationList, snapshots: snapshots)
                return (added, collected)
            }.value
            guard let self else { return }
            self.isEvaluating = false
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
        // Discovering unlocks the entries; achievements count captures (photos).
        celebration = Celebration(kind: .discovered, sights: sights, capturedCount: discoveredCount, totalCount: gameSightCount)
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

    /// Pins for the maps: discovered sights, and the others too when `showingAll`.
    /// Places of remembrance are always shown (quietly): they are not hidden as a prize.
    func pins(showingAll: Bool) -> [SightPin] {
        catalog.sights.compactMap { sight in
            let record = log.records[sight.id]
            guard record != nil || showingAll || sight.isPlaceOfRemembrance else { return nil }
            return SightPin(sight: sight, discoveredAt: record?.capturedAt, capturedAt: log.photos[sight.id]?.capturedAt)
        }
    }

    /// Station pins: collected stations, and the others too when `showingAll`.
    func stationPins(showingAll: Bool) -> [StationPin] {
        stations.stations.compactMap { station in
            let record = log.stations[station.id]
            guard record != nil || showingAll else { return nil }
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
    static func photoDirectory(for sourceID: String) -> URL {
        let safe = sourceID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("Photos").appendingPathComponent(safe)
    }

    /// The photo of a captured sight.
    func photoURL(for sight: Sight) -> URL? {
        guard let sourceID, let photo = log.photos[sight.id] else { return nil }
        return Self.photoDirectory(for: sourceID).appendingPathComponent(photo.fileName)
    }

    func photo(for sight: Sight) -> UIImage? {
        photoURL(for: sight).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// How far the position is from the sight (`nil` without a recent position).
    func distance(to sight: Sight, from location: CLLocation?) -> CLLocationDistance? {
        guard let location, location.horizontalAccuracy >= 0, location.timestamp.timeIntervalSinceNow > -300 else { return nil }
        return location.distance(from: CLLocation(latitude: sight.latitude, longitude: sight.longitude))
    }

    /// Whether a discovered sight can be photographed from here: within its extent
    /// plus `photoReach` (anywhere with the debug option). Only data sources that
    /// record this device's positions capture.
    func canPhotograph(_ sight: Sight, from location: CLLocation?) -> Bool {
        // Places of remembrance are not captured.
        guard celebrates, !sight.isPlaceOfRemembrance, log.isDiscovered(sight.id) else { return false }
        if photosAnywhere { return true }
        guard let meters = distance(to: sight, from: location) else { return false }
        return meters <= sight.radius + Self.photoReach
    }

    /// Saves the photo of a sight: it is captured (a new photo replaces an earlier
    /// one; the capture keeps its first date). Returns the celebration of a first
    /// capture, with the achievements it completes.
    func saveCapture(_ image: UIImage, of sight: Sight, at location: CLLocation?) throws -> Celebration? {
        guard let sourceID else { return nil }
        let directory = Self.photoDirectory(for: sourceID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = sight.id.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined() + ".jpg"
        guard let data = Self.scaled(image, maxSide: 2048).jpegData(compressionQuality: 0.85) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        let now = Date()
        let first = log.photos[sight.id] == nil
        log.photos[sight.id] = PhotoCapture(
            sightID: sight.id, capturedAt: log.photos[sight.id]?.capturedAt ?? now, takenAt: now,
            latitude: location?.coordinate.latitude, longitude: location?.coordinate.longitude, fileName: fileName
        )
        persist()
        guard first else { return nil }
        let unlocked = achievements.unlocked(by: [sight.id], captured: Set(log.captureDates.keys))
        return Celebration(kind: .photographed, sights: [sight], capturedCount: log.photos.count, totalCount: gameSightCount,
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
        case .landmark: return "Landmark"
        case .museum: return "Museum"
        case .palace: return "Palace"
        case .church: return "Church"
        case .viewpoint: return "Viewpoint"
        case .memorial: return "Place of remembrance"
        case .park: return "Park"
        case .square: return "Square"
        case .culture: return "Culture"
        case .monument: return "Monument"
        case .zoo: return "Zoo"
        case .bridge: return "Bridge"
        case .stadium: return "Stadium or arena"
        case .fountain: return "Fountain"
        case .market: return "Market"
        case .government: return "Seat of government"
        case .cemetery: return "Cemetery"
        case .club: return "Club"
        }
    }
}

/// The capture colour; and the quiet stone grey of places of remembrance.
extension Color {
    static let captureGold = Color(red: 1.0, green: 0.76, blue: 0.18)
    static let remembrance = Color(red: 0.42, green: 0.45, blue: 0.49)
}

extension UIColor {
    static let captureGold = UIColor(red: 1.0, green: 0.76, blue: 0.18, alpha: 1)
    static let remembrance = UIColor(red: 0.42, green: 0.45, blue: 0.49, alpha: 1)
}
