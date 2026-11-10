import Foundation
import MapQuestCore
import SwiftUI

/// The capture component (docs/02-architecture.md, "Capture"): sights of the
/// bundled cities that are captured once the fog of war around them is lifted.
/// It only reads the discovered area of the selected data source and keeps its
/// own log per data source (`FileCaptureStore`), separate from the data stores.

/// What the capture animation shows: one sight, or several at once.
struct Celebration: Identifiable, Equatable {
    let id = UUID()
    let sights: [Sight]
    let capturedCount: Int
    let totalCount: Int
}

/// A request to show a sight on the 2D map.
struct SightFocus: Equatable {
    let id: Int
    let sight: Sight
}

/// A captured sight with its record.
struct CapturedSight: Identifiable {
    let sight: Sight
    let record: CaptureRecord

    var id: String { sight.id }
}

/// A sight as drawn on the maps.
struct SightPin: Equatable, Identifiable {
    let sight: Sight
    let capturedAt: Date?

    var id: String { sight.id }
    var isCaptured: Bool { capturedAt != nil }
}

@MainActor
final class CaptureModel: ObservableObject {
    let catalog: SightCatalog
    @Published private(set) var log = CaptureLog()
    @Published private(set) var celebration: Celebration?
    @Published private(set) var focus: SightFocus?
    @Published var showsList = false

    private var store: (any CaptureStore)?
    private var sourceID: String?
    /// Only data sources that record this device's positions celebrate captures.
    private var celebrates = false
    private var pending: [DiscoveredAreaSnapshot]?
    private var isEvaluating = false
    private var focusCounter = 0

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapQuest/Captures")
    }

    init(bundle: Bundle = .main) {
        catalog = Self.loadCatalog(bundle)
    }

    /// The sight lists of all bundled cities (`<city>-sights.json`).
    static func loadCatalog(_ bundle: Bundle) -> SightCatalog {
        .merged(Cities.all.compactMap { city -> SightCatalog? in
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
        evaluateIfIdle()
    }

    /// Forgets the captures of a data source whose discovered area was deleted.
    func reset(sourceID: String) {
        guard sourceID == self.sourceID else {
            try? FileCaptureStore(directory: Self.directory, sourceID: sourceID).delete()
            return
        }
        try? store?.delete()
        log = CaptureLog()
        celebration = nil
    }

    private func switchSource(to sourceID: String, recordsLocations: Bool) {
        self.sourceID = sourceID
        celebrates = recordsLocations
        let store = FileCaptureStore(directory: Self.directory, sourceID: sourceID)
        self.store = store
        log = (try? store.load()) ?? CaptureLog()
        celebration = nil
        pending = nil
        celebrateNext()
    }

    private func evaluateIfIdle() {
        guard !isEvaluating, let snapshots = pending, let sourceID else { return }
        pending = nil
        isEvaluating = true
        let base = log
        let sights = catalog.sights
        let celebrate = celebrates
        Task { [weak self] in
            let added = await Task.detached(priority: .utility) { () -> [CaptureRecord] in
                var updated = base
                return SightCapture.update(&updated, sights: sights, snapshots: snapshots, celebrate: celebrate)
            }.value
            guard let self else { return }
            self.isEvaluating = false
            if self.sourceID == sourceID, !added.isEmpty {
                for record in added where self.log.records[record.sightID] == nil {
                    self.log.records[record.sightID] = record
                }
                self.persist()
                self.celebrateNext()
            }
            self.evaluateIfIdle()
        }
    }

    private func persist() {
        try? store?.save(log)
    }

    // MARK: Celebration

    /// Shows the next capture: one at a time, or all together when more than three wait
    /// (e.g. the first check of discoveries made before).
    private func celebrateNext() {
        guard celebration == nil, celebrates else { return }
        let waiting = log.uncelebrated
        guard let first = waiting.first else { return }
        let shown = waiting.count > 3 ? waiting : [first]
        let sights = shown.compactMap { catalog[$0.sightID] }
        guard !sights.isEmpty else {
            log.markCelebrated(shown.map(\.sightID))
            persist()
            return
        }
        celebration = Celebration(sights: sights, capturedCount: log.records.count, totalCount: catalog.count)
    }

    /// The animation ended or was tapped away.
    func finishCelebration() {
        guard let celebration else { return }
        log.markCelebrated(celebration.sights.map(\.id))
        persist()
        self.celebration = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.celebrateNext()
        }
    }

    // MARK: Views

    var capturedCount: Int { log.records.count }

    /// Captured sights, newest first.
    var captured: [CapturedSight] {
        log.records.values
            .compactMap { record in catalog[record.sightID].map { CapturedSight(sight: $0, record: record) } }
            .sorted { $0.record.capturedAt > $1.record.capturedAt }
    }

    var available: [Sight] {
        catalog.sights.filter { !log.isCaptured($0.id) }
    }

    /// Pins for the maps: captured sights, and the others too when `showingAll`.
    func pins(showingAll: Bool) -> [SightPin] {
        catalog.sights.compactMap { sight in
            let record = log.records[sight.id]
            guard record != nil || showingAll else { return nil }
            return SightPin(sight: sight, capturedAt: record?.capturedAt)
        }
    }

    /// Shows a sight on the 2D map (closes the list).
    func show(_ sight: Sight) {
        focusCounter += 1
        focus = SightFocus(id: focusCounter, sight: sight)
        showsList = false
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
        case .memorial: return "flame.fill"
        case .park: return "tree.fill"
        case .square: return "square.grid.2x2.fill"
        case .culture: return "theatermasks.fill"
        case .monument: return "flag.fill"
        case .zoo: return "pawprint.fill"
        case .bridge: return "water.waves"
        case .stadium: return "sportscourt.fill"
        }
    }

    var title: String {
        switch self {
        case .landmark: return "Landmark"
        case .museum: return "Museum"
        case .palace: return "Palace"
        case .church: return "Church"
        case .viewpoint: return "Viewpoint"
        case .memorial: return "Memorial"
        case .park: return "Park"
        case .square: return "Square"
        case .culture: return "Culture"
        case .monument: return "Monument"
        case .zoo: return "Zoo"
        case .bridge: return "Bridge"
        case .stadium: return "Stadium"
        }
    }
}

/// The capture colour.
extension Color {
    static let captureGold = Color(red: 1.0, green: 0.76, blue: 0.18)
}

extension UIColor {
    static let captureGold = UIColor(red: 1.0, green: 0.76, blue: 0.18, alpha: 1)
}
