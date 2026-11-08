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
    /// What the snapshot shows ("<layer>" for all time, "<layer>@<period>" for a
    /// period); renderers redraw partially only between versions of the same identity.
    var identity = ""
    /// Increments with every snapshot change.
    var version = 0
    /// Tiles that changed with the last update (`nil` = everything).
    var changedTiles: Set<TileKey>?
    var discoveredSquareMeters: Double = 0
    var regionCount = 0
}

/// Progress of recomputing areas after building data changed.
struct DataRefreshProgress: Equatable {
    var layer: MapLayer
    var dataTiles: Int
    var done: Int
    var total: Int

    var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
}

/// Explored data tiles (≈ 1.5 km squares) of the line-of-sight layer by data source.
struct BuildingDataSummary: Equatable {
    var bundled = 0
    var downloaded = 0
    /// Computed with the default map (radius circle): no building data yet.
    var missing = 0
    /// Waiting to be recomputed.
    var pending = 0
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
    @Published var lastOutcome: String = ""
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var playArea: PlayArea
    /// Discovered share per district of the selected layer (computed on demand).
    @Published private(set) var districtCoverage: [AreaCoverage] = []
    /// Tunable parameters (Settings › Debug).
    @Published private(set) var debug: DebugSettings
    /// Progress (0…1) of a running rebuild.
    @Published private(set) var progress: Double?
    /// What the last evaluated position revealed, shown when `debug.showsEvaluation` is on.
    @Published private(set) var evaluationSummary: String?
    /// A running refresh of areas whose building data changed.
    @Published private(set) var dataRefresh: DataRefreshProgress?
    /// Building data behind the line-of-sight layer (from its data watermarks).
    @Published private(set) var buildingData = BuildingDataSummary()
    @Published private(set) var isDownloadingBuildings = false
    /// Size of the continuous track of the selected data source.
    @Published private(set) var trackSummary = TrackSummary()

    // View options (ViewOptions.swift)
    /// Fog of war (default) or heatmap.
    @Published var aggregate: MapAggregate {
        didSet {
            UserDefaults.standard.set(aggregate.rawValue, forKey: Self.aggregateKey)
            refreshView()
        }
    }
    /// The time span shown: all time (`nil`, the default) or a day, week, month or year.
    @Published var periodKind: PeriodKind?
    /// A date inside the period shown.
    @Published var periodAnchor = Date()
    /// The area of the shown period per layer.
    @Published var periodStates: [MapLayer: LayerState] = [:]
    /// Figures of what is shown (period, or all time for the heatmap).
    @Published var viewSummary: ViewSummary?
    /// Progress (0…1) while a period is computed.
    @Published var viewProgress: Double?
    /// Weighted positions for the heatmap.
    @Published var heatPoints = HeatPoints()
    /// Whether the 3D scene is shown (it needs the line-of-sight layer).
    @Published var isShowing3D = false {
        didSet { if isShowing3D != oldValue { refreshView() } }
    }

    let tracker: LocationTracker
    let catalog: DataSourceCatalog
    private(set) var circleModel: CircleDiscoveryModel
    private(set) var viewshedModel: ViewshedDiscoveryModel
    /// Buildings for ray casting and the 3D map (bundled, cached, or downloaded on demand).
    let buildings: CachingBuildingSource
    /// Berlin's elevation model, if bundled.
    let berlinTerrain: GridTerrain?

    private(set) var store: any MapQuestDataStore
    private(set) var engines: [MapLayer: DiscoveryEngine]
    private(set) var recorder: LocationRecorder
    /// Writes every fix (≈ 1 Hz) to the track of the selected data source.
    private(set) var trackWriter: TrackWriter

    private nonisolated let sampleSink: AsyncStream<LocationSample>.Continuation
    private var processingTask: Task<Void, Never>?
    private var isRebuilding = false
    /// Data tiles whose building data changed and whose areas must be recomputed.
    private var pendingDataTiles: Set<TileKey> = []
    private var dataRefreshTask: Task<Void, Never>?
    var periodDiscovery: PeriodDiscovery
    var viewTask: Task<Void, Never>?
    var liveViewTask: Task<Void, Never>?
    var versionCounter = 0
    static let aggregateKey = "AppModel.aggregate"
    static let periodKindKey = "AppModel.periodKind"
    /// Layers that could not be built during the last reload.
    private var failedLayers: Set<MapLayer> = []
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
        let debug = DebugSettings.load()
        let buildings = Self.makeBuildingSource(downloadsAutomatically: debug.downloadsBuildings)
        let berlinTerrain = BerlinData.terrain()
        let (circleModel, viewshedModel) = Self.makeModels(debug, buildings: buildings, terrain: berlinTerrain)
        let engines = Self.makeEngines(store: store, circle: circleModel, viewshed: viewshedModel)
        self.debug = debug
        self.circleModel = circleModel
        self.viewshedModel = viewshedModel
        self.buildings = buildings
        self.berlinTerrain = berlinTerrain
        self.profile = profile
        self.profiles = catalog.profiles
        self.store = store
        self.engines = engines
        self.recorder = LocationRecorder(
            store: store, engines: MapLayer.allCases.compactMap { engines[$0] }, policy: debug.recordingPolicy, playArea: playArea
        )
        self.trackWriter = TrackWriter(store: store)
        self.periodDiscovery = PeriodDiscovery(store: store)
        self.aggregate = UserDefaults.standard.string(forKey: Self.aggregateKey).flatMap(MapAggregate.init(rawValue:)) ?? .fog
        self.periodKind = UserDefaults.standard.string(forKey: Self.periodKindKey).flatMap(PeriodKind.init(rawValue:))
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
        // Downloaded buildings make the areas around them stale (docs/05-cache-invalidation.md).
        Task { [weak self] in
            await buildings.setOnDataChange { [weak self] tiles in
                Task { @MainActor [weak self] in self?.scheduleDataRefresh(tiles) }
            }
            await self?.reload()
        }
    }

    deinit {
        sampleSink.finish()
    }

    private static func makeModels(
        _ debug: DebugSettings, buildings: CachingBuildingSource, terrain: GridTerrain?
    ) -> (CircleDiscoveryModel, ViewshedDiscoveryModel) {
        let ground: any TerrainModel
        if debug.usesTerrain, let terrain {
            ground = terrain
        } else {
            ground = FlatTerrain.berlin
        }
        return (
            CircleDiscoveryModel(radius: debug.radius),
            ViewshedDiscoveryModel(buildings: buildings, terrain: ground, configuration: debug.viewshedConfiguration)
        )
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

    /// Buildings for the line-of-sight layer and the 3D map: the bundled Berlin
    /// database (unpacked once into Application Support) layered under a cache of
    /// buildings downloaded on demand from OpenStreetMap.
    private static func makeBuildingSource(downloadsAutomatically: Bool) -> CachingBuildingSource {
        let fileManager = FileManager.default
        let directory = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("MapQuest/Buildings", isDirectory: true)
        var overlay: any BuildingCache = InMemoryBuildingCache()
        if let directory, let downloads = try? SQLiteBuildingStore(fileURL: directory.appendingPathComponent("buildings.sqlite")) {
            overlay = downloads
        }
        let cache = LayeredBuildingCache(overlay: overlay) {
            guard let directory else { return nil }
            return BundledBuildings.prepare(in: directory)
        }
        let client = OverpassClient()
        return CachingBuildingSource(
            cache: cache, download: { box in try await client.buildings(in: box) }, downloadsAutomatically: downloadsAutomatically
        )
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
        guard profile.recordsLocations else {
            lastOutcome = "Viewing \(profile.name) – not recording"
            return
        }
        // The track keeps every fix, right away – also while a layer is being rebuilt.
        await appendToTrack(sample)
        while isRebuilding {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let recorder = self.recorder
        do {
            let outcome = try await recorder.record(sample)
            guard recorder === self.recorder else { return } // data source changed meanwhile
            if debug.showsEvaluation {
                await summarizeEvaluation(of: sample, outcome: outcome)
            }
            switch outcome {
            case .recorded(_, let updates):
                sampleCount += 1
                periodViewTouched()
                lastOutcome = "New area discovered"
                for update in updates {
                    if let layer = layer(for: update.layer) {
                        await publish(layer, changedTiles: update.changedTiles)
                    }
                    // The position saw newer building data than the stored area around it.
                    scheduleDataRefresh(update.staleDataTiles)
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
            // Not an alert: with a remote data source this can happen for every fix while offline.
            lastOutcome = "Could not record position: \(error.localizedDescription)"
        }
    }

    private func layer(for id: DiscoveryLayerID) -> MapLayer? {
        engines.first { $0.value.layer == id }?.key
    }

    private func updateStaleLayers() async {
        let stale = await recorder.staleLayers
        staleLayers = Set(stale.compactMap(layer(for:))).union(failedLayers)
    }

    private func publish(_ layer: MapLayer, changedTiles: Set<TileKey>?) async {
        guard let engine = engines[layer] else { return }
        let snapshot = await engine.snapshot()
        guard engines[layer] === engine else { return }
        var state = layers[layer] ?? LayerState(snapshot: snapshot)
        state.snapshot = snapshot
        state.identity = engine.layer.rawValue
        state.version += 1
        state.changedTiles = changedTiles
        state.discoveredSquareMeters = snapshot.totalAreaSquareMeters
        state.regionCount = snapshot.regions.count
        layers[layer] = state
    }

    private func refreshAll() async {
        for layer in MapLayer.allCases {
            await publish(layer, changedTiles: nil)
        }
    }

    // MARK: Data source

    /// Reloads everything from the current store. Layers that do not exist yet
    /// (new parameters, new app version) are rebuilt from the stored positions.
    func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if profile.id == BerlinData.demoProfileID {
                let summary = try await store.trackSummary()
                if summary.pointCount == 0 {
                    // First launch, or demo data from before the track: start afresh.
                    try await store.removeAllSamples()
                    for layer in try await store.layers() { try await store.removeAllPieces(layer: layer) }
                    for engine in engines.values { await engine.invalidateCache() }
                    try await importDemoData()
                }
            }
            sampleCount = try await store.sampleCount()
            await updateTrackSummary()
            let existing = Set(try await store.layers())
            failedLayers = []
            for layer in MapLayer.allCases {
                guard let engine = engines[layer] else { continue }
                do {
                    if sampleCount > 0, !existing.contains(engine.layer) {
                        try await rebuild(engine, label: layer.title)
                    } else {
                        try await engine.loadAll()
                    }
                } catch {
                    // E.g. building data unavailable offline: keep the other layers working.
                    failedLayers.insert(layer)
                    lastOutcome = "\(layer.title) layer incomplete: \(error.localizedDescription)"
                }
            }
            await refreshAll()
            await updateStaleLayers()
            refreshView()
            // Building data may have changed since the layers were computed (downloads,
            // a newer bundled dataset after an app update): refresh those areas.
            Task { [weak self] in await self?.checkBuildingData(fetchingMissing: self?.debug.downloadsBuildings ?? false) }
        } catch {
            errorMessage = "Could not load data: \(error.localizedDescription)"
        }
    }

    /// Rebuilds one layer from the stored positions, reporting progress.
    private func rebuild(_ engine: DiscoveryEngine, label: String) async throws {
        isRebuilding = true
        defer {
            isRebuilding = false
            progress = nil
        }
        lastOutcome = "Building the \(label.lowercased()) layer…"
        progress = 0
        let samples = try await store.samples(matching: .all)
        let stale = try await engine.rebuild(from: samples) { done, total in
            Task { @MainActor [weak self] in self?.progress = Double(done) / Double(max(total, 1)) }
        }
        scheduleDataRefresh(stale)
        lastOutcome = ""
    }

    /// Switches the whole app to another data source (another user, a demo, …).
    func select(_ profile: DataProfile) async {
        guard profile.id != self.profile.id else { return }
        do {
            let store = try catalog.openStore(for: profile)
            let engines = Self.makeEngines(store: store, circle: circleModel, viewshed: viewshedModel)
            self.store = store
            self.engines = engines
            await flushTrack()
            self.recorder = LocationRecorder(store: store, engines: MapLayer.allCases.compactMap { engines[$0] }, playArea: playArea)
            self.trackWriter = TrackWriter(store: store)
            self.trackSummary = TrackSummary()
            self.periodDiscovery = PeriodDiscovery(store: store)
            self.periodStates = [:]
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

    /// Adds a MapQuest server account as a data source and switches to it.
    func addRemoteDataSource(url: URL, token: String, records: Bool) async throws {
        let profile = try await catalog.addRemoteProfile(baseURL: url, token: token, records: records)
        refreshProfiles()
        await select(profile)
    }

    /// Imports the demo explorer's track and feeds its fixes through the recorder,
    /// exactly as if they had been tracked live: only sampled fixes revealing new
    /// area become key samples.
    private func importDemoData() async throws {
        let recorder = self.recorder
        lastOutcome = "Importing the demo explorer's track…"
        let points = try BerlinData.demoTrack()
        defer { progress = nil }
        // The track goes in as segments of ten minutes.
        let segments = stride(from: 0, to: points.count, by: 600).map { start in
            TrackSegment(points: Array(points[start..<min(start + 600, points.count)]))
        }
        for batch in stride(from: 0, to: segments.count, by: 50) {
            try await store.putTrackSegments(Array(segments[batch..<min(batch + 50, segments.count)]))
        }
        for (index, point) in points.enumerated() {
            _ = try await recorder.record(point.sample)
            if index % 500 == 499 {
                progress = Double(index + 1) / Double(points.count)
            }
            if index % 10_000 == 9_999 {
                // Let the map fill up while the import runs.
                sampleCount = try await store.sampleCount()
                await refreshAll()
            }
        }
        try await recorder.finishSampling()
        await updateTrackSummary()
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

    // MARK: Debug

    /// Applies new debug settings. Changed discovery parameters switch to other
    /// layers, which are rebuilt from the stored positions where needed.
    func applyDebugSettings(_ settings: DebugSettings) async {
        let previous = debug
        debug = settings
        settings.save()
        await recorder.setPolicy(settings.recordingPolicy)
        if !settings.showsEvaluation { evaluationSummary = nil }
        if settings.downloadsBuildings != previous.downloadsBuildings {
            await buildings.setDownloadsAutomatically(settings.downloadsBuildings)
            if settings.downloadsBuildings { Task { await checkBuildingData(fetchingMissing: true) } }
        }
        guard settings.changesLayers(comparedTo: previous) else { return }
        let (circle, viewshed) = Self.makeModels(settings, buildings: buildings, terrain: berlinTerrain)
        circleModel = circle
        viewshedModel = viewshed
        let engines = Self.makeEngines(store: store, circle: circle, viewshed: viewshed)
        self.engines = engines
        recorder = LocationRecorder(
            store: store, engines: MapLayer.allCases.compactMap { engines[$0] }, policy: settings.recordingPolicy, playArea: playArea
        )
        layers = Self.emptyLayers(engines)
        await reload()
    }

    /// Records a test position at `coordinate` with the debug eye height, as if it had been tracked.
    func placeTestPosition(at coordinate: GeoCoordinate) async {
        let ground = viewshedModel.terrain.elevation(at: WebMercator.project(coordinate))
        let altitude = viewshedModel.configuration.altitude(forEyeHeight: debug.testEyeHeight, groundElevation: ground, verticalAccuracy: 1)
        let sample = LocationSample(
            coordinate: coordinate, altitude: altitude, horizontalAccuracy: 3, verticalAccuracy: 1, timestamp: Date()
        )
        await process(sample)
    }

    /// Deletes cached discovered area of layers that the current settings do not use.
    func deleteUnusedLayers() async {
        do {
            let used = Set(engines.values.map(\.layer))
            // Cached days of the current layers (time-based views) are kept.
            for layer in try await store.layers() where !used.contains(layer) {
                let base = DiscoveryLayerID(String(layer.rawValue.prefix { $0 != "@" }))
                if layer.rawValue.contains("@day:"), used.contains(base) { continue }
                try await store.removeAllPieces(layer: layer)
            }
            lastOutcome = "Unused layers deleted"
        } catch {
            errorMessage = "Could not delete layers: \(error.localizedDescription)"
        }
    }

    private func summarizeEvaluation(of sample: LocationSample, outcome: RecordingOutcome) async {
        let evaluations = await recorder.lastEvaluations
        var lines: [String] = []
        switch outcome {
        case .recorded: lines.append("stored")
        case .alreadyDiscovered(let evaluated) where evaluated.isEmpty: lines.append("skipped by the sampler (≈ every \(Int(debug.minimumMovement)) m)")
        case .alreadyDiscovered: lines.append("not stored")
        case .rejected(let reason): lines.append("rejected: \(reason)")
        }
        for evaluation in evaluations {
            let name = layer(for: evaluation.layer)?.title ?? evaluation.layer.rawValue
            lines.append(String(
                format: "%@: %.0f m² new of %.0f m² (%.0f %%)",
                name, evaluation.newAreaSquareMeters, evaluation.revealedAreaSquareMeters, evaluation.newAreaFraction * 100
            ))
        }
        let heights = viewshedModel.heights(for: sample)
        let ground = viewshedModel.terrain.elevation(at: sample.worldPoint)
        lines.append(String(
            format: "altitude %.0f m (±%.0f), ground %.0f m, eye %.1f m, above surroundings %.0f m, sight %.0f m",
            sample.altitude, sample.verticalAccuracy, ground, heights.eye, heights.effective,
            viewshedModel.configuration.viewDistance(eyeHeight: heights.effective)
        ))
        evaluationSummary = lines.joined(separator: "\n")
    }

    // MARK: Track

    private func appendToTrack(_ sample: LocationSample) async {
        do {
            if try await trackWriter.append(TrackPoint(sample)) {
                trackSummary.pointCount += 1
                trackSummary.last = sample.timestamp
                if trackSummary.first == nil { trackSummary.first = sample.timestamp }
            }
        } catch {
            lastOutcome = "Could not write the track: \(error.localizedDescription)"
        }
    }

    /// Writes buffered fixes (when the app goes to the background) and evaluates
    /// the last fix the sampler skipped.
    func flushTrack() async {
        try? await trackWriter.flush()
        if profile.recordsLocations, !isRebuilding {
            _ = try? await recorder.finishSampling()
        }
    }

    func updateTrackSummary() async {
        if let summary = try? await store.trackSummary() {
            let pending = await trackWriter.pendingPointCount
            var adjusted = summary
            adjusted.pointCount += pending
            trackSummary = adjusted
        }
    }

    // MARK: Building data and cache invalidation

    /// Queues data tiles whose building data changed; their areas are recomputed
    /// in the background (DRed over the influence zone, docs/05-cache-invalidation.md).
    func scheduleDataRefresh(_ tiles: Set<TileKey>) {
        guard !tiles.isEmpty else { return }
        pendingDataTiles.formUnion(tiles)
        startDataRefresh()
    }

    private func startDataRefresh() {
        guard dataRefreshTask == nil, !pendingDataTiles.isEmpty else { return }
        dataRefreshTask = Task { [weak self] in
            // Downloads of neighbouring tiles usually arrive together: collect them first.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.runDataRefresh()
        }
    }

    private func runDataRefresh() async {
        while !pendingDataTiles.isEmpty {
            while isRebuilding {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let tiles = pendingDataTiles
            pendingDataTiles = []
            let store = self.store
            for (layer, engine) in engines.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where engine.model.usesMapData {
                dataRefresh = DataRefreshProgress(layer: layer, dataTiles: tiles.count, done: 0, total: 0)
                do {
                    let result = try await engine.refresh(dataTiles: tiles, locations: store) { done, total in
                        Task { @MainActor [weak self] in
                            guard self?.dataRefresh?.layer == layer else { return }
                            self?.dataRefresh?.done = done
                            self?.dataRefresh?.total = total
                        }
                    }
                    pendingDataTiles.formUnion(result.staleDataTiles)
                    if engines[layer] === engine {
                        await publish(layer, changedTiles: result.changedTiles)
                    }
                    if result.affectedSamples > 0 {
                        lastOutcome = "\(layer.title) updated for new building data (\(result.recomputedSamples) positions)"
                    }
                } catch {
                    lastOutcome = "Could not update \(layer.title.lowercased()): \(error.localizedDescription)"
                }
            }
        }
        await updateBuildingDataSummary()
        // No suspension from here on: tiles queued meanwhile start the next run.
        dataRefresh = nil
        dataRefreshTask = nil
        startDataRefresh()
    }

    /// Compares the data the layers were computed from with the current building
    /// data and refreshes what changed. With `fetchingMissing`, first tries to
    /// download data for explored areas that have none.
    func checkBuildingData(fetchingMissing: Bool) async {
        for engine in engines.values where engine.model.usesMapData {
            if let stale = try? await engine.staleDataTiles(fetchingMissing: fetchingMissing) {
                scheduleDataRefresh(stale)
            }
        }
        await updateBuildingDataSummary()
    }

    /// Downloads building data for explored areas that were computed with the
    /// default map (radius circle); those areas are then recomputed.
    func downloadMissingBuildingData() async {
        guard let engine = engines[.lineOfSight] else { return }
        isDownloadingBuildings = true
        defer { isDownloadingBuildings = false }
        let missing = Set(((try? await engine.dataWatermarks()) ?? [:]).filter { $0.value == DataGrid.noData }.keys)
        guard !missing.isEmpty else {
            lastOutcome = "Building data is available for all explored areas"
            return
        }
        lastOutcome = "Downloading building data for \(missing.count) \(missing.count == 1 ? "tile" : "tiles")…"
        let stale = (try? await engine.staleDataTiles(fetchingMissing: true)) ?? []
        scheduleDataRefresh(stale)
        let downloaded = stale.intersection(missing).count
        lastOutcome = downloaded == missing.count
            ? "Building data downloaded – updating the line of sight…"
            : "Downloaded \(downloaded) of \(missing.count) tiles (offline or server busy? Try again later)"
        await updateBuildingDataSummary()
    }

    private func updateBuildingDataSummary() async {
        guard let engine = engines[.lineOfSight], let marks = try? await engine.dataWatermarks() else { return }
        var summary = BuildingDataSummary()
        for version in marks.values {
            if version == DataGrid.noData {
                summary.missing += 1
            } else if version.hasPrefix("bundle:") {
                summary.bundled += 1
            } else {
                summary.downloaded += 1
            }
        }
        summary.pending = pendingDataTiles.count
        buildingData = summary
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
            let stale = try await recorder.rebuildAllLayers()
            scheduleDataRefresh(stale)
            failedLayers = []
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
            await flushTrack()
            try await store.removeAllSamples()
            try await store.removeAllTrack()
            trackSummary = TrackSummary()
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
