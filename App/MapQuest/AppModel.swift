import Combine
import CoreLocation
import Foundation
import MapQuestCore

/// Wires the three components together: location tracking → recorder →
/// discovered area → map. Owns the currently selected data source.
@MainActor
final class AppModel: ObservableObject {
    struct Statistics: Equatable {
        var sampleCount = 0
        var discoveredSquareMeters: Double = 0
        var regionCount = 0
        /// Discovered share of the play area (0…1), if the play area is bounded.
        var playAreaFraction: Double?
    }

    @Published private(set) var profile: DataProfile
    @Published private(set) var profiles: [DataProfile]
    /// The 2D discovered area of the selected data source.
    @Published private(set) var snapshot: DiscoveredAreaSnapshot
    /// Tiles that changed with the last snapshot update (`nil` = everything).
    @Published private(set) var changedTiles: Set<TileKey>?
    @Published private(set) var statistics = Statistics()
    @Published private(set) var lastOutcome: String = ""
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var playArea: PlayArea

    let tracker: LocationTracker
    let catalog: DataSourceCatalog
    let circleModel: CircleDiscoveryModel

    private(set) var store: any MapQuestDataStore
    private(set) var circleEngine: DiscoveryEngine
    private(set) var recorder: LocationRecorder

    private nonisolated let sampleSink: AsyncStream<LocationSample>.Continuation
    private var processingTask: Task<Void, Never>?
    private var isRebuilding = false

    init(catalog: DataSourceCatalog = DataSourceCatalog(), tracker: LocationTracker = LocationTracker()) {
        self.catalog = catalog
        self.tracker = tracker
        let playArea = PlayArea.world
        self.playArea = playArea

        let profile = catalog.selectedProfile
        let store: any MapQuestDataStore
        var openError: Error?
        do {
            store = try catalog.openStore(for: profile)
        } catch {
            openError = error
            store = InMemoryDataStore()
        }
        let circleModel = CircleDiscoveryModel(radius: 50)
        let engine = DiscoveryEngine(model: circleModel, store: store)
        self.circleModel = circleModel
        self.profile = profile
        self.profiles = catalog.profiles
        self.store = store
        self.circleEngine = engine
        self.recorder = LocationRecorder(store: store, engines: [engine], playArea: playArea)
        self.snapshot = .empty(layer: engine.layer)

        let (samples, sink) = AsyncStream<LocationSample>.makeStream(bufferingPolicy: .bufferingNewest(1_000))
        self.sampleSink = sink
        // All stored properties are initialised from here on.
        if let openError { errorMessage = openError.localizedDescription }
        tracker.onLocations = { locations in
            for location in locations {
                sink.yield(LocationSample(location))
            }
        }
        processingTask = Task { [weak self] in
            for await sample in samples {
                guard let self else { return }
                await self.process(sample)
            }
        }
        Task { await reload() }
    }

    deinit {
        sampleSink.finish()
    }

    // MARK: Processing

    private func process(_ sample: LocationSample) async {
        while isRebuilding {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard profile.recordsLocations else {
            lastOutcome = "Viewing \(profile.name) – not recording"
            return
        }
        let recorder = self.recorder
        do {
            let outcome = try await recorder.record(sample)
            guard recorder === self.recorder else { return } // data source changed meanwhile
            switch outcome {
            case .recorded(_, let updates):
                statistics.sampleCount += 1
                lastOutcome = "New area discovered"
                await refreshSnapshot(changedTiles: updates.reduce(into: Set<TileKey>()) { $0.formUnion($1.changedTiles) })
            case .alreadyDiscovered:
                lastOutcome = "Known territory"
            case .rejected(.inaccurate):
                lastOutcome = "Waiting for a precise position"
            case .rejected(.outsidePlayArea):
                lastOutcome = "Outside \(playArea.name)"
            case .rejected(.invalidPosition):
                lastOutcome = "No valid position"
            }
        } catch {
            errorMessage = "Could not record position: \(error.localizedDescription)"
        }
    }

    private func refreshSnapshot(changedTiles: Set<TileKey>?) async {
        let engine = circleEngine
        let snapshot = await engine.snapshot()
        guard engine === circleEngine else { return }
        self.snapshot = snapshot
        self.changedTiles = changedTiles
        statistics.discoveredSquareMeters = snapshot.totalAreaSquareMeters
        statistics.regionCount = snapshot.regions.count
        if !playArea.isWorld, playArea.areaSquareMeters > 0 {
            statistics.playAreaFraction = min(1, snapshot.totalAreaSquareMeters / playArea.areaSquareMeters)
        } else {
            statistics.playAreaFraction = nil
        }
    }

    // MARK: Data source

    /// Reloads everything from the current store.
    func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await circleEngine.loadAll()
            statistics.sampleCount = try await store.sampleCount()
            await refreshSnapshot(changedTiles: nil)
        } catch {
            errorMessage = "Could not load data: \(error.localizedDescription)"
        }
    }

    /// Switches the whole app to another data source (another user, a demo, …).
    func select(_ profile: DataProfile) async {
        guard profile.id != self.profile.id else { return }
        do {
            let store = try catalog.openStore(for: profile)
            let engine = DiscoveryEngine(model: circleModel, store: store)
            self.store = store
            self.circleEngine = engine
            self.recorder = LocationRecorder(store: store, engines: [engine], playArea: playArea)
            self.profile = profile
            catalog.selectedProfileID = profile.id
            snapshot = .empty(layer: engine.layer)
            statistics = Statistics()
            lastOutcome = ""
            await reload()
        } catch {
            errorMessage = "Could not open \(profile.name): \(error.localizedDescription)"
        }
    }

    func refreshProfiles() {
        profiles = catalog.profiles
    }

    func setPlayArea(_ area: PlayArea) async {
        playArea = area
        await recorder.setPlayArea(area)
        await refreshSnapshot(changedTiles: nil)
    }

    // MARK: Maintenance

    /// Recomputes the discovered area from the stored location samples.
    func rebuildDiscoveredArea() async {
        isBusy = true
        isRebuilding = true
        defer {
            isRebuilding = false
            isBusy = false
        }
        do {
            try await recorder.rebuildAllLayers()
            await refreshSnapshot(changedTiles: nil)
        } catch {
            errorMessage = "Rebuild failed: \(error.localizedDescription)"
        }
    }

    /// Deletes all samples and discovered area of the selected data source.
    func deleteAllData() async {
        isBusy = true
        isRebuilding = true
        defer {
            isRebuilding = false
            isBusy = false
        }
        do {
            try await store.removeAllSamples()
            for layer in try await store.layers() {
                try await store.removeAllPieces(layer: layer)
            }
            await circleEngine.invalidateCache()
            try await circleEngine.loadAll()
            statistics = Statistics()
            await refreshSnapshot(changedTiles: nil)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}
