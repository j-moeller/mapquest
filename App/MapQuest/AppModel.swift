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
        case .radius: return tr("Radius")
        case .lineOfSight: return tr("Line of sight")
        }
    }

    /// The title inside a sentence ("Updating line of sight …"; German nouns keep their capital).
    var titleInSentence: String {
        switch self {
        case .radius: return tr("radius")
        case .lineOfSight: return tr("line of sight")
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

/// Discovered share of a city and its districts.
struct CityCoverage: Identifiable {
    var city: AreaCoverage
    var districts: [AreaCoverage]
    var id: String { city.name }
}

/// Progress of recomputing areas after building data changed.
struct DataRefreshProgress: Equatable {
    var layer: MapLayer
    var dataTiles: Int
    var done: Int
    var total: Int

    var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
}

/// The distance walked (metres).
struct WalkedDistances: Equatable {
    var today: Double
    var thisWeek: Double
    var total: Double
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
    /// What happened to the latest position ("Known territory", …). Every fix sets it;
    /// it is published only when it changes, so the views are not redrawn every second.
    var lastOutcome: String {
        get { outcomeText }
        set { if newValue != outcomeText { outcomeText = newValue } }
    }
    @Published private var outcomeText = ""
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    /// The cities with bundled 3D data, together (outlined on the map). Positions
    /// are recorded and the fog of war lifts everywhere; only building downloads
    /// are limited to these cities.
    @Published private(set) var cityArea: PlayArea
    /// The bundled cities (each with its districts).
    let cities: [PlayArea]
    /// Discovered share per city and district of the selected layer (computed on demand).
    @Published private(set) var districtCoverage: [CityCoverage] = []
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
    /// Size of the continuous track of the selected data source, published at most
    /// every `trackPublishInterval` (it grows with every fix); `liveTrackSummary` is current.
    @Published private(set) var trackSummary = TrackSummary()
    private(set) var liveTrackSummary = TrackSummary()
    private var trackPublishedAt = Date.distantPast
    static let trackPublishInterval: TimeInterval = 10

    /// What the line of sight showed from the latest evaluated position (not published:
    /// read when deciding whether the camera may open).
    private(set) var currentView: LineOfSightView?

    /// The app is in the background: the maps and time views are not updated (they
    /// catch up when it comes back) and the tracker may save power while the phone is still.
    private(set) var isInBackground = false
    /// Layer changes made in the background, published when the app comes back.
    private var deferredLayerChanges: [MapLayer: DeferredChange] = [:]
    private enum DeferredChange {
        case tiles(Set<TileKey>)
        case all
    }

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
    /// The debug panel over the map (Debug/DebugPanel.swift).
    @Published var showsDebugPanel = false
    /// Open the debug panel once the settings sheet is gone.
    var opensDebugPanelAfterSettings = false
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
    /// The cities' elevation models, if bundled.
    let cityTerrain: CompositeTerrain?

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
        let cities = Cities.playAreas()
        self.cities = cities
        self.cityArea = Cities.combined(cities)
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
        let cityTerrain = Cities.terrain()
        let (circleModel, viewshedModel) = Self.makeModels(debug, buildings: buildings, terrain: cityTerrain)
        let engines = Self.makeEngines(store: store, circle: circleModel, viewshed: viewshedModel)
        self.debug = debug
        self.circleModel = circleModel
        self.viewshedModel = viewshedModel
        self.buildings = buildings
        self.cityTerrain = cityTerrain
        self.profile = profile
        self.profiles = catalog.profiles
        self.store = store
        self.engines = engines
        self.recorder = LocationRecorder(
            store: store, engines: MapLayer.allCases.compactMap { engines[$0] }, policy: debug.recordingPolicy
        )
        self.trackWriter = TrackWriter(store: store)
        self.periodDiscovery = PeriodDiscovery(store: store)
        // No GPS for data sources that record nothing (another user's data, the demo).
        tracker.isRecordingAllowed = profile.recordsLocations
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
        // Buildings are downloaded only around the cities with bundled 3D data (elsewhere:
        // the default map), unless the debug setting allows it everywhere.
        let region: (@Sendable (TileKey) -> Bool)? = debug.downloadsBuildingsEverywhere ? nil : Self.downloadRegion(cities)
        // Downloaded buildings make the areas around them stale (docs/05-cache-invalidation.md).
        Task { [weak self] in
            await buildings.setDownloadRegion(region)
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
        _ debug: DebugSettings, buildings: CachingBuildingSource, terrain: CompositeTerrain?
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
            return Cities.bundledBuildings(in: directory)
        }
        let client = OverpassClient()
        return CachingBuildingSource(
            cache: cache, download: { box in try await client.buildings(in: box) }, downloadsAutomatically: downloadsAutomatically
        )
    }

    /// Data tiles near a city with bundled data (its outline's bounds grown by 2 km,
    /// so tiles across the city limits are downloaded as well).
    static func downloadRegion(_ cities: [PlayArea]) -> @Sendable (TileKey) -> Bool {
        let boxes = cities.compactMap { city -> WorldRect? in
            guard let bounds = city.bounds else { return nil }
            let latitude = WebMercator.unproject(bounds.center).latitude
            return bounds.expanded(by: Int64(2_000 / WebMercator.metersPerUnit(atLatitude: latitude)))
        }
        return { tile in boxes.contains { $0.intersects(tile.worldRect) } }
    }

    // MARK: Convenience for views

    func state(_ layer: MapLayer) -> LayerState {
        layers[layer] ?? LayerState(snapshot: .empty(layer: DiscoveryLayerID(layer.rawValue)))
    }

    /// The city the user is in (or was last), else the most discovered one.
    func focusCity(_ layer: MapLayer) -> PlayArea? {
        if let location = tracker.lastLocation,
           let city = cities.first(where: { $0.contains(GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)) }) {
            return city
        }
        // Elsewhere: the city with the most discovered area, if any (e.g. viewing another user's data).
        let best = cities.max { discovered(layer, in: $0) < discovered(layer, in: $1) }
        return best.flatMap { discovered(layer, in: $0) > 0 ? $0 : nil }
    }

    /// Discovered area of a layer inside a city's bounding box (cities are far apart).
    private func discovered(_ layer: MapLayer, in city: PlayArea) -> Double {
        guard let bounds = city.bounds else { return 0 }
        return state(layer).snapshot.piecesByTile
            .filter { bounds.contains($0.key.worldRect.center) }
            .reduce(0) { $0 + $1.value.reduce(0) { $0 + $1.areaSquareMeters } }
    }

    /// Discovered share of the city in focus for a layer.
    func playAreaFraction(_ layer: MapLayer) -> (city: String, fraction: Double)? {
        guard let city = focusCity(layer), city.areaSquareMeters > 0 else { return nil }
        return (city.name, min(1, discovered(layer, in: city) / city.areaSquareMeters))
    }

    // MARK: Processing

    private func process(_ sample: LocationSample) async {
        guard profile.recordsLocations else {
            lastOutcome = tr("Viewing {0} – not recording", profile.name)
            return
        }
        // The track keeps every fix, right away – also while a layer is being rebuilt; coarse
        // positions (Wi-Fi and cell, while the tracker saves power) stay out of it.
        if sample.horizontalAccuracy <= Self.maximumTrackAccuracy {
            await appendToTrack(sample)
        }
        while isRebuilding {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let recorder = self.recorder
        do {
            let outcome = try await recorder.record(sample)
            guard recorder === self.recorder else { return } // data source changed meanwhile
            await updateCurrentView()
            if debug.showsEvaluation {
                await summarizeEvaluation(of: sample, outcome: outcome)
            }
            switch outcome {
            case .recorded(_, let updates):
                sampleCount += 1
                periodViewTouched()
                lastOutcome = tr("New area discovered")
                for update in updates {
                    if let layer = layer(for: update.layer) {
                        await publishOrDefer(layer, changedTiles: update.changedTiles)
                    }
                    // The position saw newer building data than the stored area around it.
                    scheduleDataRefresh(update.staleDataTiles)
                }
            case .alreadyDiscovered:
                lastOutcome = tr("Known territory")
            case .rejected(.inaccurate):
                lastOutcome = tr("Waiting for a precise position")
            case .rejected(.outsidePlayArea):
                lastOutcome = tr("Outside the recording area")
            case .rejected(.invalidPosition):
                lastOutcome = tr("No valid position")
            }
            await updateStaleLayers()
        } catch {
            // Not an alert: with a remote data source this can happen for every fix while offline.
            lastOutcome = tr("Could not record position: {0}", error.localizedDescription)
        }
    }

    /// Keeps what the line of sight showed from the latest evaluated position.
    private func updateCurrentView() async {
        guard let layer = engines[.lineOfSight]?.layer,
              let evaluation = await recorder.lastEvaluations.first(where: { $0.layer == layer }),
              evaluation.sample.timestamp != currentView?.sample.timestamp else { return }
        currentView = LineOfSightView(sample: evaluation.sample, revealed: evaluation.revealed)
    }

    /// The distance walked today, this week and in all, from the track (`TrackStatistics.walkedMeters`).
    func walkedDistances() async -> WalkedDistances? {
        try? await trackWriter.flush()
        let store = self.store
        guard let points = try? await store.trackPoints() else { return nil }
        let calendar = Calendar.current
        return await Task.detached(priority: .utility) {
            let byDay = TrackStatistics.walkedMetersByDay(points, calendar: calendar)
            let today = calendar.startOfDay(for: Date())
            let week = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? today
            return WalkedDistances(
                today: byDay[today] ?? 0,
                thisWeek: byDay.filter { $0.key >= week }.values.reduce(0, +),
                total: byDay.values.reduce(0, +)
            )
        }.value
    }

    private func layer(for id: DiscoveryLayerID) -> MapLayer? {
        engines.first { $0.value.layer == id }?.key
    }

    private func updateStaleLayers() async {
        let stale = Set(await recorder.staleLayers.compactMap(layer(for:))).union(failedLayers)
        if stale != staleLayers { staleLayers = stale }
    }

    /// Publishes a layer's change, or – in the background – keeps it for when the app comes back.
    private func publishOrDefer(_ layer: MapLayer, changedTiles: Set<TileKey>?) async {
        guard isInBackground else { return await publish(layer, changedTiles: changedTiles) }
        switch (deferredLayerChanges[layer], changedTiles) {
        case (.all, _), (_, nil):
            deferredLayerChanges[layer] = .all
        case (.tiles(let earlier), let tiles?):
            deferredLayerChanges[layer] = .tiles(earlier.union(tiles))
        case (nil, let tiles?):
            deferredLayerChanges[layer] = .tiles(tiles)
        }
    }

    // MARK: Foreground and background

    /// Fixes less precise than this (metres) are not kept in the track.
    static let maximumTrackAccuracy: Double = 100

    /// Called when the app goes to the background or comes back.
    func setInBackground(_ background: Bool) {
        guard background != isInBackground else { return }
        isInBackground = background
        tracker.isInBackground = background
        if background {
            liveViewTask?.cancel()
            liveViewTask = nil
            return
        }
        publishTrackSummary(force: true)
        let deferred = deferredLayerChanges
        deferredLayerChanges = [:]
        Task { [weak self] in
            guard let self else { return }
            for (layer, change) in deferred {
                switch change {
                case .all: await self.publish(layer, changedTiles: nil)
                case .tiles(let tiles): await self.publish(layer, changedTiles: tiles)
                }
            }
            if self.periodKind != nil || self.aggregate == .heatmap { self.refreshView() }
        }
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
                        try await rebuild(engine, label: layer.titleInSentence)
                    } else {
                        try await engine.loadAll()
                    }
                } catch {
                    // E.g. building data unavailable offline: keep the other layers working.
                    failedLayers.insert(layer)
                    lastOutcome = tr("{0} layer incomplete: {1}", layer.title, error.localizedDescription)
                }
            }
            await refreshAll()
            await updateStaleLayers()
            refreshView()
            // Building data may have changed since the layers were computed (downloads,
            // a newer bundled dataset after an app update): refresh those areas.
            Task { [weak self] in await self?.checkBuildingData(fetchingMissing: self?.debug.downloadsBuildings ?? false) }
            // Gaps left before positions that fill gaps were stored: fill them from the track, once.
            if !UserDefaults.standard.bool(forKey: gapsFilledKey) {
                Task { [weak self] in await self?.fillGapsFromTrack(automatically: true) }
            }
        } catch {
            errorMessage = tr("Could not load data: {0}", error.localizedDescription)
        }
    }

    /// Rebuilds one layer from the stored positions, reporting progress.
    /// - Parameter label: the layer's title inside a sentence (`MapLayer.titleInSentence`).
    private func rebuild(_ engine: DiscoveryEngine, label: String) async throws {
        isRebuilding = true
        defer {
            isRebuilding = false
            progress = nil
        }
        lastOutcome = tr("Building the {0} layer…", label)
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
            self.recorder = LocationRecorder(store: store, engines: MapLayer.allCases.compactMap { engines[$0] }, policy: debug.recordingPolicy)
            self.trackWriter = TrackWriter(store: store)
            setTrackSummary(TrackSummary())
            self.periodDiscovery = PeriodDiscovery(store: store)
            self.periodStates = [:]
            self.profile = profile
            tracker.isRecordingAllowed = profile.recordsLocations
            catalog.selectedProfileID = profile.id
            layers = Self.emptyLayers(engines)
            sampleCount = 0
            staleLayers = []
            districtCoverage = []
            lastOutcome = ""
            await reload()
        } catch {
            errorMessage = tr("Could not open {0}: {1}", profile.name, error.localizedDescription)
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

    /// Imports the demo explorer's track and feeds its fixes through the recorder.
    /// The track is first reduced by the coverage sampler with revisits merged:
    /// the ten repeated commutes would be known territory live anyway, so the
    /// key samples are (nearly) the same at a fraction of the evaluations.
    private func importDemoData() async throws {
        let recorder = self.recorder
        lastOutcome = tr("Importing the demo explorer's track…")
        let points = try BerlinData.demoTrack()
        defer { progress = nil }
        // The whole track goes in as segments of ten minutes.
        let segments = stride(from: 0, to: points.count, by: 600).map { start in
            TrackSegment(points: Array(points[start..<min(start + 600, points.count)]))
        }
        for batch in stride(from: 0, to: segments.count, by: 50) {
            try await store.putTrackSegments(Array(segments[batch..<min(batch + 50, segments.count)]))
        }
        let sampling = debug.recordingPolicy.sampling.offline
        let samples = await Task.detached(priority: .userInitiated) {
            CoverageSampler.reduce(points.map(\.sample), configuration: sampling)
        }.value
        for (index, sample) in samples.enumerated() {
            _ = try await recorder.record(sample)
            if index % 50 == 49 {
                progress = Double(index + 1) / Double(samples.count)
            }
            if index % 500 == 499 {
                // Let the map fill up while the import runs.
                sampleCount = try await store.sampleCount()
                await refreshAll()
            }
        }
        try await recorder.finishSampling()
        await updateTrackSummary()
        lastOutcome = ""
    }

    /// Computes the discovered share of every city and district for the selected layer (off the main thread).
    func computeDistrictCoverage() async {
        let snapshot = state(selectedLayer).snapshot
        let cities = self.cities
        districtCoverage = await Task.detached(priority: .userInitiated) {
            cities.map { city in
                let coverage = DiscoveryStatistics.coverage(of: snapshot, in: [city] + city.subdivisions)
                return CityCoverage(city: coverage[0], districts: coverage.dropFirst().sorted { $0.fraction > $1.fraction })
            }
        }.value
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
        if settings.downloadsBuildingsEverywhere != previous.downloadsBuildingsEverywhere {
            await buildings.setDownloadRegion(settings.downloadsBuildingsEverywhere ? nil : Self.downloadRegion(cities))
            if settings.downloadsBuildings { Task { await checkBuildingData(fetchingMissing: true) } }
        }
        if settings.downloadsBuildings != previous.downloadsBuildings {
            await buildings.setDownloadsAutomatically(settings.downloadsBuildings)
            if settings.downloadsBuildings { Task { await checkBuildingData(fetchingMissing: true) } }
        }
        guard settings.changesLayers(comparedTo: previous) else { return }
        let (circle, viewshed) = Self.makeModels(settings, buildings: buildings, terrain: cityTerrain)
        circleModel = circle
        viewshedModel = viewshed
        let engines = Self.makeEngines(store: store, circle: circle, viewshed: viewshed)
        self.engines = engines
        recorder = LocationRecorder(
            store: store, engines: MapLayer.allCases.compactMap { engines[$0] }, policy: settings.recordingPolicy
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
            lastOutcome = tr("Unused layers deleted")
        } catch {
            errorMessage = tr("Could not delete layers: {0}", error.localizedDescription)
        }
    }

    private func summarizeEvaluation(of sample: LocationSample, outcome: RecordingOutcome) async {
        let evaluations = await recorder.lastEvaluations
        var lines: [String] = []
        func number(_ value: Double, digits: Int = 0) -> String { Formatters.decimal(value, digits: digits) }
        switch outcome {
        case .recorded: lines.append(tr("stored"))
        case .alreadyDiscovered(let evaluated) where evaluated.isEmpty:
            lines.append(tr("skipped by the sampler (≈ every {0} m)", Int(debug.minimumMovement)))
        case .alreadyDiscovered: lines.append(tr("not stored"))
        // The reason is the case's name (inaccurate, outsidePlayArea, …): a symbol for developers.
        case .rejected(let reason): lines.append(tr("rejected: {0}", String(describing: reason)))
        }
        for evaluation in evaluations {
            let name = layer(for: evaluation.layer)?.title ?? evaluation.layer.rawValue
            lines.append(tr(
                "{0}: {1} m² new of {2} m² ({3} %)",
                name, number(evaluation.newAreaSquareMeters), number(evaluation.revealedAreaSquareMeters),
                number(evaluation.newAreaFraction * 100)
            ))
        }
        let heights = viewshedModel.heights(for: sample)
        let ground = viewshedModel.terrain.elevation(at: sample.worldPoint)
        lines.append(tr(
            "altitude {0} m (±{1}), ground {2} m, eye {3} m, above surroundings {4} m, sight {5} m",
            number(sample.altitude), number(sample.verticalAccuracy), number(ground), number(heights.eye, digits: 1),
            number(heights.effective), number(viewshedModel.configuration.viewDistance(eyeHeight: heights.effective))
        ))
        evaluationSummary = lines.joined(separator: "\n")
    }

    // MARK: Track

    private func appendToTrack(_ sample: LocationSample) async {
        do {
            if try await trackWriter.append(TrackPoint(sample)) {
                liveTrackSummary.pointCount += 1
                liveTrackSummary.last = sample.timestamp
                if liveTrackSummary.first == nil { liveTrackSummary.first = sample.timestamp }
                publishTrackSummary(force: false)
            }
        } catch {
            lastOutcome = tr("Could not write the track: {0}", error.localizedDescription)
        }
    }

    /// Publishes the track's size: at most every `trackPublishInterval`, not in the background.
    private func publishTrackSummary(force: Bool) {
        let now = Date()
        guard force || (!isInBackground && now.timeIntervalSince(trackPublishedAt) >= Self.trackPublishInterval) else { return }
        trackPublishedAt = now
        if trackSummary != liveTrackSummary { trackSummary = liveTrackSummary }
    }

    private func setTrackSummary(_ summary: TrackSummary) {
        liveTrackSummary = summary
        publishTrackSummary(force: true)
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
            setTrackSummary(adjusted)
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
                        lastOutcome = trn(
                            "{1} updated for new building data ({2} position)", "{1} updated for new building data ({2} positions)",
                            result.recomputedSamples, layer.title, Formatters.number(result.recomputedSamples)
                        )
                    }
                } catch {
                    lastOutcome = tr("Could not update {0}: {1}", layer.titleInSentence, error.localizedDescription)
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
        var missing = Set<TileKey>()
        for (tile, version) in (try? await engine.dataWatermarks()) ?? [:] where version == DataGrid.noData {
            if await buildings.mayDownload(tile) { missing.insert(tile) }
        }
        guard !missing.isEmpty else {
            lastOutcome = tr("Building data is available for all explored areas in the cities")
            return
        }
        lastOutcome = trn("Downloading building data for {0} tile…", "Downloading building data for {0} tiles…", missing.count)
        let stale = (try? await engine.staleDataTiles(fetchingMissing: true)) ?? []
        scheduleDataRefresh(stale)
        let downloaded = stale.intersection(missing).count
        lastOutcome = downloaded == missing.count
            ? tr("Building data downloaded – updating the line of sight…")
            : tr("Downloaded {0} of {1} tiles (offline or server busy? Try again later)", downloaded, missing.count)
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
            lastOutcome = tr("Rebuilding discovered area…")
            let stale = try await recorder.rebuildAllLayers()
            scheduleDataRefresh(stale)
            failedLayers = []
            lastOutcome = tr("Discovered area rebuilt")
        } catch {
            errorMessage = tr("Rebuild failed: {0}", error.localizedDescription)
        }
        await refreshAll()
        await updateStaleLayers()
    }

    /// Set once a data source's gaps were filled from its track (`fillGapsFromTrack`).
    private var gapsFilledKey: String { Self.gapsFilledKey(for: profile.id) }
    private static func gapsFilledKey(for sourceID: String) -> String {
        "AppModel.gapsFilledFromTrack.v1." + sourceID // not localized
    }

    /// Fills the gaps of the discovered area – fog enclosed by discovered area, which
    /// earlier versions left black although you walked through it – from the
    /// positions in the track (`LocationRecorder.fillGaps`).
    func fillGapsFromTrack(automatically: Bool = false) async {
        if automatically {
            // After whatever else is running at launch.
            while isBusy { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        guard !isBusy else { return }
        isBusy = true
        defer {
            isBusy = false
            progress = nil
        }
        let recorder = self.recorder
        let key = gapsFilledKey
        do {
            await flushTrack()
            let points = try await store.trackPoints()
            if !automatically { lastOutcome = tr("Filling gaps from your track…") }
            let repair = try await recorder.fillGaps(from: points, reach: circleModel.radius) { done, total in
                Task { @MainActor [weak self] in self?.progress = Double(done) / Double(max(total, 1)) }
            }
            guard recorder === self.recorder else { return } // data source changed meanwhile
            UserDefaults.standard.set(true, forKey: key)
            if repair.storedPositions > 0 {
                sampleCount = try await store.sampleCount()
                scheduleDataRefresh(repair.staleDataTiles)
                periodViewTouched()
                await refreshAll()
            }
            if repair.storedPositions > 0 || !automatically {
                lastOutcome = repair.gaps == 0
                    ? tr("No gaps in the discovered area")
                    : tr("Gaps: {0} found, {1} positions from your track added",
                         Formatters.number(repair.gaps), Formatters.number(repair.storedPositions))
            }
        } catch {
            if !automatically { errorMessage = tr("Could not fill gaps: {0}", error.localizedDescription) }
        }
    }

    // MARK: Export and import

    /// Whether an import may replace the selected data source's data (a database on this device).
    var canReplaceSelectedData: Bool {
        if case .localDatabase = profile.descriptor.kind { return true }
        return false
    }

    /// Writes everything of the selected data source – positions, track, captures,
    /// photos and the settings – into a ZIP file for the share sheet (`DataArchive`).
    func exportData(captures: CaptureModel) async throws -> (url: URL, manifest: DataArchive.Manifest) {
        isBusy = true
        defer {
            isBusy = false
            progress = nil
        }
        lastOutcome = tr("Preparing the export…")
        await flushTrack()
        let samples = try await store.samples(matching: .all)
        let track = try await store.trackPoints()
        let export = DataArchive.Export(
            source: .init(id: profile.id, name: profile.name), app: Self.appVersion,
            samples: samples, track: track, captureLog: captures.log(for: profile.id),
            photoDirectory: CaptureModel.photoDirectory(for: profile.id),
            settings: try? JSONEncoder().encode(ExportedSettings(debug: debug, mapIcons: captures.iconFilter,
                                                                 savesToPhotos: CaptureModel.savesToPhotos))
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true) // not localized: a folder
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let day = Date().formatted(.iso8601.year().month().day())
        let safeName = profile.name.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let url = folder.appendingPathComponent("MapQuest-\(safeName)-\(day).zip") // not localized: a file name
        let manifest = try await Task.detached(priority: .userInitiated) {
            try DataArchive.write(export, to: url) { fraction in
                Task { @MainActor [weak self] in self?.progress = fraction }
            }
        }.value
        lastOutcome = tr("Export ready")
        return (url, manifest)
    }

    /// Where an import goes: over the selected data source, or into a new one.
    enum ImportTarget {
        case replaceSelected
        case newDataSource
    }

    /// Restores an export: its positions, track, captures and photos replace the
    /// selected data source's (with its settings), or become a new view-only data
    /// source. The discovered area is then rebuilt from the positions.
    func importData(_ reader: DataArchive.Reader, into target: ImportTarget, captures: CaptureModel) async throws {
        guard !isBusy else { return }
        isBusy = true
        isRebuilding = true  // live positions wait meanwhile
        defer {
            isRebuilding = false
            isBusy = false
            progress = nil
        }
        let name = reader.manifest.source.name
        lastOutcome = tr("Importing “{0}”…", name)
        let profile: DataProfile
        let store: any MapQuestDataStore
        switch target {
        case .replaceSelected:
            guard canReplaceSelectedData else { return }
            await flushTrack()
            profile = self.profile
            store = self.store
        case .newDataSource:
            profile = catalog.addLocalProfile(named: tr("{0} (imported)", name))
            store = try catalog.openStore(for: profile)
        }
        try await DataArchive.restorePositions(from: reader, into: store) { fraction in
            Task { @MainActor [weak self] in self?.progress = fraction * 0.8 }
        }
        let log = try reader.captureLog()
        let sourceID = profile.id
        try await Task.detached(priority: .userInitiated) {
            try CaptureModel.restorePhotos(from: reader, sourceID: sourceID)
        }.value
        progress = 0.9
        captures.adopt(log, sourceID: sourceID)
        // Gaps are looked for again in the restored area.
        UserDefaults.standard.removeObject(forKey: Self.gapsFilledKey(for: sourceID))
        isRebuilding = false
        isBusy = false
        switch target {
        case .replaceSelected:
            if let data = try reader.settings(), let settings = try? JSONDecoder().decode(ExportedSettings.self, from: data) {
                captures.iconFilter = settings.mapIcons
                UserDefaults.standard.set(settings.savesToPhotos, forKey: CaptureModel.savesToPhotosKey)
                for engine in engines.values { await engine.invalidateCache() }
                await applyDebugSettings(settings.debug)
            }
            for engine in engines.values { await engine.invalidateCache() }
            periodDiscovery = PeriodDiscovery(store: store)
            periodStates = [:]
            await reload()
        case .newDataSource:
            refreshProfiles()
            await select(profile)
        }
        lastOutcome = tr("“{0}” imported", name)
    }

    /// "1.0 (42)", for exports.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "MapQuest \(version) (\(build))" // not localized
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
            setTrackSummary(TrackSummary())
            for layer in try await store.layers() {
                try await store.removeAllPieces(layer: layer)
            }
            for engine in engines.values {
                await engine.invalidateCache()
                try await engine.loadAll()
            }
            sampleCount = 0
            await refreshAll()
            // Other components (captures) forget what depended on the deleted area.
            NotificationCenter.default.post(name: .discoveredDataDeleted, object: profile.id)
        } catch {
            errorMessage = tr("Delete failed: {0}", error.localizedDescription)
        }
    }
}
