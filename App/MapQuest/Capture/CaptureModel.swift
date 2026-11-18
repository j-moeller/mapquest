import CoreLocation
import Foundation
import ImageIO
import MapQuestCore
import SwiftUI
import UIKit

/// The capture component (docs/02-architecture.md, "Capture"): sights of the
/// installed sight packages are discovered once the fog of war around them is lifted – the
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

/// A region with sights (a city), as the installed packages name it.
struct SightRegion: Hashable, Identifiable {
    let id: String
    let name: String
}

@MainActor
final class CaptureModel: ObservableObject {
    /// The installed sight packages, resolved (docs/09-sight-packages.md): the sights,
    /// their entries and facts, achievements, places of remembrance and stations all
    /// come from them. Reloaded when packages are added or removed.
    @Published private(set) var library: SightLibrary
    /// Package files that could not be read (menu › Sight packages names them).
    @Published private(set) var unreadablePackages: [String] = []
    let packageStore: SightPackageStore
    let bundle: Bundle
    /// Packages read from a file or link, shown before they are added.
    @Published var packageOffer: PackageOffer?
    /// What adding packages did, or why a file could not be read.
    @Published var packageMessage: String?

    var catalog: SightCatalog { library.catalog }
    /// The sights' entries (unlocked by discovering them), in the app's language (English where a sight has none in it).
    var infos: SightInfoCatalog { library.infos(Localization.language) }
    /// The sights' historical facts (unlocked with their entries), in the app's language;
    /// achievements are decided on the English ones.
    var histories: SightHistoryCatalog { library.histories(Localization.language) }
    /// The stations and lines.
    var stations: StationCatalog { library.stations }
    /// The sights of the game: all but the places of remembrance, which are not captured.
    var gameSightCount: Int { catalog.sights.filter { !$0.isPlaceOfRemembrance }.count }
    /// The achievements of all packages, each resolved against its package's sights and stations.
    var achievements: AchievementBook { library.achievements }
    /// The regions with sights or stations (Berlin, Braunschweig), in the packages' order.
    var sightCities: [SightRegion] {
        library.regions
            .filter { region in library.regionOfSight.values.contains(region.id) || library.regionOfStation.values.contains(region.id) }
            .map { SightRegion(id: $0.id, name: $0.name()) }
    }
    /// The region whose sights, achievements and places of remembrance the list shows:
    /// where you are (`follow(_:)`), else the last one; kept across launches.
    @Published var cityID: String {
        didSet { UserDefaults.standard.set(cityID, forKey: Self.cityKey) }
    }
    private static let cityKey = "CaptureModel.city" // not localized
    /// The places of remembrance as a short history and as walks, outside the game, in the app's language.
    var remembrance: RemembranceGuide { library.remembrance(Localization.language) }
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
    /// Sights of packages just added are checked without celebrations: they were
    /// reached before, not now.
    private var checksQuietly = false
    private var pending: [DiscoveredAreaSnapshot]?
    /// How far the radius layer may end from a sight for it to be nearby (`SightCapture.nearbyTolerance`).
    private var nearbyTolerance = SightCapture.nearbyTolerance(circleRadius: 50)
    /// The area last checked (to check again after a reset).
    private var lastSnapshots: [DiscoveredAreaSnapshot] = []
    private var isEvaluating = false
    private var focusCounter = 0
    /// Lines completed by collected stations, waiting for their celebration.
    private var lineCelebrations: [Achievement] = []
    /// The packages that come with the app, read when first asked for.
    private var bundledPackages: [SightPackage]?

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapQuest/Captures")
    }

    /// Where the installed sight packages are kept (one file per package).
    nonisolated static var packageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapQuest/SightPackages")
    }

    init(bundle: Bundle = .main, packageDirectory: URL = CaptureModel.packageDirectory) {
        let packageStore = SightPackageStore(directory: packageDirectory)
        BundledPackages.installNew(from: bundle, into: packageStore)
        let installed = packageStore.installed()
        let library = SightLibrary(packages: installed.packages)
        self.packageStore = packageStore
        self.bundle = bundle
        self.library = library
        let savedCity = UserDefaults.standard.string(forKey: Self.cityKey)
        let regions = library.regions.map(\.id)
        cityID = savedCity.flatMap { regions.contains($0) ? $0 : nil } ?? regions.first ?? "berlin" // not localized
        unreadablePackages = installed.unreadable
        SightCategory.hierarchy = library.categories
    }

    // MARK: Sight packages

    /// Reads the installed packages again (after adding or removing one) and checks
    /// the new sights against the area discovered so far – quietly: they were reached
    /// before. What was captured under a merged ID counts for the place it was merged into.
    func reloadPackages() {
        let installed = packageStore.installed()
        let library = SightLibrary(packages: installed.packages)
        SightCategory.hierarchy = library.categories
        unreadablePackages = installed.unreadable
        self.library = library
        if !library.regions.contains(where: { $0.id == cityID }), let first = library.regions.first {
            cityID = first.id
        }
        if log.adoptAliases(library.aliases) { persist() }
        checksQuietly = true
        pending = lastSnapshots
        evaluateIfIdle()
    }

    /// Installs the packages of a file (one package or a bundle) and reloads.
    func installPackages(from data: Data) throws -> [PackageInstallResult] {
        let packages = try SightPackageFile.decode(data)
        let outcomes = try packageStore.install(packages)
        BundledPackages.forgetRemoved(packages.map(\.id))
        reloadPackages()
        return outcomes.map { result in
            PackageInstallResult(id: result.id, title: packages.first { $0.id == result.id }?.title() ?? result.id,
                                 outcome: result.outcome)
        }
    }

    /// Removes an installed package (one that came with the app is not installed again by itself).
    func removePackage(_ id: String) {
        try? packageStore.remove(id)
        BundledPackages.noteRemoved(id)
        reloadPackages()
    }

    /// The packages that come with the app but are not installed (removed, or newer here).
    var availableBundledPackages: [SightPackage] {
        let installed = Dictionary(library.packages.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        if bundledPackages == nil { bundledPackages = BundledPackages.packages(in: bundle) }
        return (bundledPackages ?? []).filter { package in
            installed[package.id].map { SightPackage.isVersion(package.version, newerThan: $0) } ?? true
        }
    }

    /// Installs packages that come with the app.
    func installBundled(_ packages: [SightPackage]) {
        _ = try? packageStore.install(packages)
        BundledPackages.forgetRemoved(packages.map(\.id))
        reloadPackages()
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
        if log.adoptAliases(library.aliases) { persist() }
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
        let celebrate = celebrates && !checksQuietly
        checksQuietly = false
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

    /// Photographed sights (of the installed packages: captures of removed ones are kept, not counted).
    var capturedCount: Int { capturedCount(in: nil) }
    /// Visited sights of the game (entries unlocked); places of remembrance do not count.
    var discoveredCount: Int { discoveredCount(in: nil) }
    var collectedStationCount: Int { log.stations.keys.filter { stations[$0] != nil }.count }

    /// Progress of every achievement.
    var achievementProgress: [AchievementProgress] { achievements.progress(log) }

    // MARK: Regions

    /// The region of a sight or achievement (`SightRegion.id`).
    func city(of id: String) -> String? { library.regionOfSight[id] ?? library.regionOfAchievement[id] }

    /// The region the list shows.
    var currentCity: SightRegion? { sightCities.first { $0.id == cityID } }

    /// The region of a station: the one its package names.
    func city(ofStation station: Station) -> String? { library.regionOfStation[station.id] }

    /// Follows where you are: the list switches to the region you are in (elsewhere it stays).
    func follow(_ cityID: String?) {
        guard let cityID, cityID != self.cityID, sightCities.contains(where: { $0.id == cityID }) else { return }
        self.cityID = cityID
    }

    /// The region at a position: a city whose outline the app has (`outlines`) and
    /// contains it, else the smallest region whose bounds contain it.
    func region(at coordinate: GeoCoordinate, outlines: [PlayArea]) -> String? {
        if let area = outlines.first(where: { $0.contains(coordinate) }),
           let city = Cities.all.first(where: { $0.name == area.name }),
           sightCities.contains(where: { $0.id == city.id }) {
            return city.id
        }
        var best: (id: String, size: Double)?
        for region in library.regions {
            guard let bounds = region.bounds, bounds.contains(coordinate) else { continue }
            let size = (bounds.north - bounds.south) * (bounds.east - bounds.west)
            if best == nil || size < best!.size { best = (region.id, size) }
        }
        return best?.id
    }

    /// The sights of a region (all with `nil`).
    func sights(in city: String?) -> [Sight] {
        guard let city else { return catalog.sights }
        return catalog.sights.filter { library.regionOfSight[$0.id] == city }
    }

    /// The sights of the game in a region: places of remembrance do not count.
    func gameSightCount(in city: String?) -> Int { sights(in: city).filter { !$0.isPlaceOfRemembrance }.count }
    /// Photographed sights in a region (sights of installed packages only).
    func capturedCount(in city: String?) -> Int {
        log.photos.keys.filter { catalog[$0] != nil && (city == nil || library.regionOfSight[$0] == city) }.count
    }
    /// Discovered sights of the game in a region.
    func discoveredCount(in city: String?) -> Int {
        log.records.keys.filter { id in
            guard let sight = catalog[id], !sight.isPlaceOfRemembrance else { return false }
            return city == nil || library.regionOfSight[id] == city
        }.count
    }
    /// Progress of the achievements of a region.
    func achievementProgress(in city: String?) -> [AchievementProgress] {
        achievementProgress.filter { city == nil || library.regionOfAchievement[$0.id] == city }
    }
    /// The places of remembrance of a region, as chapters and walks.
    func remembrance(in city: String?) -> RemembranceGuide {
        guard let city else { return remembrance }
        let guide = remembrance
        return RemembranceGuide(
            chapters: guide.chapters.filter { $0.places.contains { library.regionOfSight[$0.sight] == city } },
            tours: guide.tours.filter { $0.stops.contains { library.regionOfSight[$0] == city } }
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

    /// Whether the sight's entry shows photorealistic 3D buildings (else its photo): in
    /// regions where Apple Maps has them (`City.hasPhotorealistic3D`).
    func hasPhotorealistic3D(_ sight: Sight) -> Bool {
        guard let region = library.regionOfSight[sight.id] else { return false }
        return Cities.all.contains { $0.id == region && $0.hasPhotorealistic3D }
    }

    /// Discovered sights whose entry has not been opened yet (not places of
    /// remembrance: their entries are open to all, nothing is "new" about them).
    func hasUnreadEntry(_ sight: Sight) -> Bool {
        !sight.isPlaceOfRemembrance && log.hasUnreadEntry(sight.id)
    }

    var unreadEntryCount: Int {
        log.records.keys.filter { !log.readEntries.contains($0) && catalog[$0].map { !$0.isPlaceOfRemembrance } ?? false }.count
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

/// Icons and names of the sight categories: the core vocabulary's here, declared
/// ones' from their packages (`CategoryDefinition`), else their parent's.
extension SightCategory {
    /// The categories of the installed packages (set by `CaptureModel`).
    static var hierarchy = CategoryHierarchy.core

    /// The core category it falls under: what the map filter and the list group by.
    var core: SightCategory { Self.hierarchy.core(of: self) }

    /// Places of remembrance: declared categories as their package or parent says.
    var isPlaceOfRemembrance: Bool { Self.hierarchy.isRemembrance(self) }

    var symbol: String {
        for member in Self.hierarchy.ancestry(of: self) {
            if let symbol = Self.hierarchy.definitions[member]?.symbol { return symbol }
            if member.isCore { return member.coreSymbol }
        }
        return SightCategory.landmark.coreSymbol
    }

    var title: String {
        if let definition = Self.hierarchy.definitions[self] { return definition.title() }
        return core.coreTitle
    }

    private var coreSymbol: String {
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
        default: return "star.fill"
        }
    }

    private var coreTitle: String {
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
        default: return tr("Landmark")
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
