import Combine
import CoreLocation
import Foundation
import MapQuestCore
import MapQuestSQLite

/// The discovered-area layers the app maintains for every data source.
enum MapLayer: String, CaseIterable, Identifiable {
    /// 2D: everything within 50 m of a position.
    case radius
    /// 3D: what is visible from a position between the buildings.
    case lineOfSight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .radius: return "Radius"
        case .lineOfSight: return "Line of sight"
        }
    }
}

/// Published state of one layer.
struct LayerState {
    var snapshot: DiscoveredAreaSnapshot
    /// Increments with every snapshot change.
    var version = 0
    /// Tiles that changed with the last update (`nil` = everything).
    var changedTiles: Set<TileKey>?
    var discoveredSquareMeters: Double = 0
    var regionCount = 0
}

/// Wires the three components together: location tracking → recorder →
/// discovered area (2D and 3D layers) → maps. Owns the selected data source.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profile: DataProfile
    @Published private(set) var profiles: [DataProfile]
    @Published private(set) var layers: [MapLayer: LayerState]
    /// The layer shown on the 2D map.
    @Published var selectedLayer: MapLayer {
        didSet { UserDefaults.standard.set(selectedLayer.rawValue, forKey: Self.selectedLayerKey) }
    }
    /// Layers that missed samples (e.g. building data was unavailable offline) and need a rebuild.
    @Published private(set) var staleLayers: Set<MapLayer> = []
    @Published private(set) var sampleCount = 0
    @Published private(set) var lastOutcome: String = ""
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var playArea: PlayArea
    /// Discovered share per district of the selected layer (computed on demand).
    @Published private(set) var districtCoverage: [AreaCoverage] = []

    let tracker: LocationTracker
    let catalog: DataSourceCatalog
    let circleModel: CircleDiscoveryModel
    let viewshedModel: ViewshedDiscoveryModel
    /// Buildings for ray casting and the 3D map (bundled, cached, or downloaded on demand).
    let buildings: CachingBuildingSource

    private(set) var store: any MapQuestDataStore
    private(set) var engines: [MapLayer: DiscoveryEngine]
    private(set) var recorder: LocationRecorder

    private nonisolated let sampleSink: AsyncStream<LocationSample>.Continuation
    private var processingTask: Task<Void, Never>?
    private var isRebuilding = false
    private static let selectedLayerKey = "AppModel.selectedLayer"

    init(catalog: DataSourceCatalog = DataSourceCatalog(), tracker: LocationTracker = LocationTracker()) {
        self.catalog = catalog
        self.tracker = tracker
        let playArea = BerlinData.playArea() ?? .world
        self.playArea = playArea
        if !catalog.profiles.contains(where: { $0.id == BerlinData.demoProfileID }) {
            catalog.upsert(BerlinData.demoProfile)
        }

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
        let buildings = Self.makeBuildingSource()
        let viewshedModel = ViewshedDiscoveryModel(buildings: buildings, terrain: FlatTerrain.berlin)
        let engines = Self.makeEngines(store: store, circle: circleModel, viewshed: viewshedModel)
        self.circleModel = circleModel
        self.viewshedModel = viewshedModel
        self.buildings = buildings
        self.profile = profile
        self.profiles = catalog.profiles
        self.store = store
        self.engines = engines
        self.recorder = LocationRecorder(store: store, engines: MapLayer.allCases.compactMap { engines[$0] }, playArea: playArea)
        self.layers = Self.emptyLayers(engines)
        self.selectedLayer = UserDefaults.standard.string(forKey: Self.selectedLayerKey).flatMap(MapLayer.init(rawValue:)) ?? .radius

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

    private static func makeEngines(store: any MapQuestDataStore, circle: CircleDiscoveryModel, viewshed: ViewshedDiscoveryModel) -> [MapLayer: DiscoveryEngine] {
        [
            .radius: DiscoveryEngine(model: circle, store: store),
            .lineOfSight: DiscoveryEngine(model: viewshed, store: store),
        ]
    }

    private static func emptyLayers(_ engines: [MapLayer: DiscoveryEngine]) -> [MapLayer: LayerState] {
        engines.mapValues { LayerState(snapshot: .empty(layer: $0.layer)) }
    }

    /// The shared building database in Application Support, seeded from a bundled
    /// `berlin-buildings.sqlite` if the app ships one, plus on-demand OSM downloads.
    private static func makeBuildingSource() -> CachingBuildingSource {
        let fileManager = FileManager.default
        let directory = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("MapQuest/Buildings", isDirectory: true)
        var cache: any BuildingCache = InMemoryBuildingCache()
        if let directory {
            let url = directory.appendingPathComponent("buildings.sqlite")
            if !fileManager.fileExists(atPath: url.path),
               let bundled = Bundle.main.url(forResource: "berlin-buildings", withExtension: "sqlite") {
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try? fileManager.copyItem(at: bundled, to: url)
            }
            if let store = try? SQLiteBuildingStore(fileURL: url) {
                cache = store
            }
        }
        let client = OverpassClient()
        return CachingBuildingSource(cache: cache, download: { box in try await client.buildings(in: box) })
    }

    // MARK: Convenience for views

    func state(_ layer: MapLayer) -> LayerState {
        layers[layer] ?? LayerState(snapshot: .empty(layer: DiscoveryLayerID(layer.rawValue)))
    }

    /// Discovered share of the play area for a layer, if the play area is bounded.
    func playAreaFraction(_ layer: MapLayer) -> Double? {
        guard !playArea.isWorld, playArea.areaSquareMeters > 0 else { return nil }
        return min(1, state(layer).discoveredSquareMeters / playArea.areaSquareMeters)
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
                sampleCount += 1
                lastOutcome = "New area discovered"
                for update in updates {
                    if let layer = layer(for: update.layer) {
                        await refresh(layer, changedTiles: update.changedTiles)
                    }
                }
            case .alreadyDiscovered:
                lastOutcome = "Known territory"
            case .rejected(.inaccurate):
                lastOutcome = "Waiting for a precise position"
            case .rejected(.outsidePlayArea):
                lastOutcome = "Outside \(playArea.name)"
            case .rejected(.invalidPosition):
                lastOutcome = "No valid position"
            }
            await updateStaleLayers()
        } catch {
            errorMessage = "Could not record position: \(error.localizedDescription)"
        }
    }

    private func layer(for id: DiscoveryLayerID) -> MapLayer? {
        engines.first { $0.value.layer == id }?.key
    }

    private func updateStaleLayers() async {
        let stale = await recorder.staleLayers
        staleLayers = Set(stale.compactMap(layer(for:)))
    }

    private func refresh(_ layer: MapLayer, changedTiles: Set<TileKey>?) async {
        guard let engine = engines[layer] else { return }
        let snapshot = await engine.snapshot()
        guard engines[layer] === engine else { return }
        var state = layers[layer] ?? LayerState(snapshot: snapshot)
        state.snapshot = snapshot
        state.version += 1
        state.changedTiles = changedTiles
        state.discoveredSquareMeters = snapshot.totalAreaSquareMeters
        state.regionCount = snapshot.regions.count
        layers[layer] = state
    }

    private func refreshAll() async {
        for layer in MapLayer.allCases {
            await refresh(layer, changedTiles: nil)
        }
    }

    // MARK: Data source

    /// Reloads everything from the current store.
    func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if profile.id == BerlinData.demoProfileID, try await store.sampleCount() == 0 {
                try await importDemoData()
            }
            for engine in engines.values {
                try await engine.loadAll()
            }
            sampleCount = try await store.sampleCount()
            await refreshAll()
            await updateStaleLayers()
        } catch {
            errorMessage = "Could not load data: \(error.localizedDescription)"
        }
    }

    /// Switches the whole app to another data source (another user, a demo, …).
    func select(_ profile: DataProfile) async {
        guard profile.id != self.profile.id else { return }
        do {
            let store = try catalog.openStore(for: profile)
            let engines = Self.makeEngines(store: store, circle: circleModel, viewshed: viewshedModel)
            self.store = store
            self.engines = engines
            self.recorder = LocationRecorder(store: store, engines: MapLayer.allCases.compactMap { engines[$0] }, playArea: playArea)
            self.profile = profile
            catalog.selectedProfileID = profile.id
            layers = Self.emptyLayers(engines)
            sampleCount = 0
            staleLayers = []
            districtCoverage = []
            lastOutcome = ""
            await reload()
        } catch {
            errorMessage = "Could not open \(profile.name): \(error.localizedDescription)"
        }
    }

    func refreshProfiles() {
        profiles = catalog.profiles
    }

    /// Feeds the demo explorer's raw fixes through the recorder, exactly as if
    /// they had been tracked live: only fixes revealing new area are stored.
    private func importDemoData() async throws {
        let recorder = self.recorder
        lastOutcome = "Importing demo walks…"
        for fix in try BerlinData.demoFixes() {
            _ = try await recorder.record(fix)
        }
        lastOutcome = ""
    }

    /// Computes the discovered share of every district for the selected layer (off the main thread).
    func computeDistrictCoverage() async {
        let snapshot = state(selectedLayer).snapshot
        let districts = playArea.subdivisions
        let coverage = await Task.detached(priority: .userInitiated) {
            DiscoveryStatistics.coverage(of: snapshot, in: districts)
        }.value
        districtCoverage = coverage.sorted { $0.fraction > $1.fraction }
    }

    // MARK: Maintenance

    /// Recomputes all discovered-area layers from the stored location samples.
    func rebuildDiscoveredArea() async {
        isBusy = true
        isRebuilding = true
        defer {
            isRebuilding = false
            isBusy = false
        }
        do {
            lastOutcome = "Rebuilding discovered area…"
            try await recorder.rebuildAllLayers()
            lastOutcome = "Discovered area rebuilt"
        } catch {
            errorMessage = "Rebuild failed: \(error.localizedDescription)"
        }
        await refreshAll()
        await updateStaleLayers()
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
            for engine in engines.values {
                await engine.invalidateCache()
                try await engine.loadAll()
            }
            sampleCount = 0
            await refreshAll()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}
