import Foundation

/// How much new area a sample would reveal for one layer.
public struct DiscoveryEvaluation: Sendable {
    public var sample: LocationSample
    public var layer: DiscoveryLayerID
    /// The full area revealed by the sample (world coordinates).
    public var revealed: [WorldPolygon]
    /// Area of `revealed` in m².
    public var revealedAreaSquareMeters: Double
    /// Part of `revealed` not discovered before, in m².
    public var newAreaSquareMeters: Double
    /// The map data the result was computed from (empty for models without map data).
    public var dataVersions: DataVersions = [:]

    public var newAreaFraction: Double {
        revealedAreaSquareMeters > 0 ? newAreaSquareMeters / revealedAreaSquareMeters : 0
    }
}

/// The result of merging revealed area into a layer.
public struct DiscoveryUpdate: Sendable {
    public var layer: DiscoveryLayerID
    /// Storage tiles whose pieces changed (including relabelled pieces in loaded tiles).
    public var changedTiles: Set<TileKey>
    /// Regions that received area (one per connected component of the revealed area).
    public var regionIDs: [UUID]
    /// Regions that ceased to exist because they were merged into another region.
    public var mergedRegionIDs: [UUID]
    /// The change set that was written to the store.
    public var changes: DiscoveredAreaChangeSet
    /// Data tiles whose data changed since the layer was made consistent with
    /// them (the sample saw newer data): the layer should be refreshed there.
    public var staleDataTiles: Set<TileKey> = []
}

/// The result of refreshing a layer after map data changed (`DiscoveryEngine.refresh`).
public struct DiscoveryRefresh: Sendable {
    public var layer: DiscoveryLayerID
    /// Data tiles that were refreshed.
    public var dataTiles: Set<TileKey> = []
    /// Samples whose result depended on the refreshed data.
    public var affectedSamples = 0
    /// Samples that were evaluated again (the affected ones and their neighbours).
    public var recomputedSamples = 0
    /// Storage tiles that were cleared and rederived.
    public var clearedTiles: Set<TileKey> = []
    /// Storage tiles whose pieces changed (including relabelled pieces).
    public var changedTiles: Set<TileKey> = []
    /// Regions that ceased to exist (merged into another region, or vanished).
    public var removedRegionIDs: Set<UUID> = []
    /// Regions that were created by splits.
    public var createdRegionIDs: Set<UUID> = []
    /// Data tiles that are still stale (their data changed again during the refresh).
    public var staleDataTiles: Set<TileKey> = []

    public init(layer: DiscoveryLayerID) {
        self.layer = layer
    }
}

/// An immutable copy of a layer's discovered area, indexed by storage tile, for
/// rendering and statistics. Safe to read from any thread.
public struct DiscoveredAreaSnapshot: Sendable {
    public let layer: DiscoveryLayerID
    public let piecesByTile: [TileKey: [DiscoveredPiece]]
    /// The overlap margin pieces may extend beyond their tile, in world units (upper bound).
    public let maximumMarginUnits: Int64

    public init(layer: DiscoveryLayerID, piecesByTile: [TileKey: [DiscoveredPiece]], maximumMarginUnits: Int64) {
        self.layer = layer
        self.piecesByTile = piecesByTile
        self.maximumMarginUnits = maximumMarginUnits
    }

    public static func empty(layer: DiscoveryLayerID) -> DiscoveredAreaSnapshot {
        DiscoveredAreaSnapshot(layer: layer, piecesByTile: [:], maximumMarginUnits: 0)
    }

    public var pieceCount: Int { piecesByTile.values.reduce(0) { $0 + $1.count } }

    public var totalAreaSquareMeters: Double {
        piecesByTile.values.reduce(0) { sum, pieces in pieces.reduce(sum) { $0 + $1.areaSquareMeters } }
    }

    public var regions: [DiscoveredRegion] {
        DiscoveredRegion.aggregate(piecesByTile.values.flatMap { $0 })
    }

    /// Pieces whose bounds intersect `rect`.
    public func pieces(intersecting rect: WorldRect) -> [DiscoveredPiece] {
        let range = TileRange(covering: rect.expanded(by: maximumMarginUnits), zoom: DiscoveryGrid.zoom)
        var result: [DiscoveredPiece] = []
        if range.count <= piecesByTile.count {
            for tile in range {
                guard let pieces = piecesByTile[tile] else { continue }
                result += pieces.filter { $0.polygon.bounds.intersects(rect) }
            }
        } else {
            for (tile, pieces) in piecesByTile where range.contains(tile) {
                result += pieces.filter { $0.polygon.bounds.intersects(rect) }
            }
        }
        return result
    }

    /// Whether a point lies in discovered area.
    public func isDiscovered(_ point: WorldPoint) -> Bool {
        region(at: point) != nil
    }

    /// The region containing a point, if any.
    public func region(at point: WorldPoint) -> UUID? {
        let tile = TileKey(containing: point, zoom: DiscoveryGrid.zoom)
        return piecesByTile[tile]?.first { $0.polygon.contains(point) }?.regionID
    }
}

/// The discovered-area component for one layer: evaluates how much new area a
/// sample reveals, merges revealed area into tiled pieces, keeps regions
/// (connected components) up to date, rebuilds the layer from samples, and
/// refreshes the parts that depend on map data when that data changes.
///
/// See docs/02-architecture.md ("Discovered area") for the algorithm and
/// docs/05-cache-invalidation.md for the refresh (DRed over the influence zone).
public actor DiscoveryEngine {
    public struct Configuration: Sendable {
        /// Pieces are clipped to their tile grown by this margin (metres). Must be ≥ `adjacencyTolerance`.
        public var overlapMargin: Double
        /// Areas closer than this (metres) count as adjacent and are merged into one region.
        public var adjacencyTolerance: Double
        /// Vertices deviating less than this (metres) are removed after each union.
        public var simplificationTolerance: Double

        public init(overlapMargin: Double = 2, adjacencyTolerance: Double = 1, simplificationTolerance: Double = 0.05) {
            precondition(overlapMargin >= adjacencyTolerance, "overlap margin must cover the adjacency tolerance")
            self.overlapMargin = overlapMargin
            self.adjacencyTolerance = adjacencyTolerance
            self.simplificationTolerance = simplificationTolerance
        }
    }

    public nonisolated let model: any DiscoveryModel
    public nonisolated let store: any DiscoveredAreaStore
    public nonisolated let configuration: Configuration
    public nonisolated var layer: DiscoveryLayerID { model.layer }

    private var cache: [TileKey: [DiscoveredPiece]] = [:]
    private var loadedTiles: Set<TileKey> = []
    private var isFullyLoaded = false
    /// When each known region was first discovered. Exact once the layer is fully
    /// loaded; decides which region survives a merge (the oldest one keeps its ID).
    private var regionFirstDiscovered: [UUID: Date] = [:]
    /// The layer's data watermarks (`nil` until loaded).
    private var watermarks: DataVersions?
    /// Rebuilds and refreshes run one at a time.
    private var isExclusive = false
    private var exclusiveWaiters: [CheckedContinuation<Void, Never>] = []
    /// Results committed while a refresh computes (it must include them).
    private var commitLog: [Contribution]?
    /// The last store write: writes are chained so that they reach the store in
    /// the order in which the in-memory state changed.
    private var lastWrite: Task<Void, Error>?

    /// The revealed area of one sample, ready to be merged.
    private struct Contribution {
        var sampleID: UUID?
        var date: Date
        var components: [WorldPolygon]
        var dataVersions: DataVersions
    }

    public init(model: any DiscoveryModel, store: any DiscoveredAreaStore, configuration: Configuration = Configuration()) {
        self.model = model
        self.store = store
        self.configuration = configuration
    }

    // MARK: Loading

    /// Loads the whole layer into memory (needed before taking a snapshot for rendering).
    public func loadAll() async throws {
        guard !isFullyLoaded else { return }
        let pieces = try await store.pieces(layer: layer, tiles: nil)
        cache = Dictionary(grouping: pieces, by: \.tile)
        isFullyLoaded = true
        loadedTiles.removeAll()
        regionFirstDiscovered.removeAll()
        noteRegionAges(of: pieces)
    }

    /// Forgets cached pieces, e.g. after the store was modified externally.
    public func invalidateCache() {
        cache.removeAll()
        loadedTiles.removeAll()
        isFullyLoaded = false
        regionFirstDiscovered.removeAll()
        watermarks = nil
    }

    private func ensureLoaded(_ range: TileRange) async throws {
        guard !isFullyLoaded else { return }
        let missing = range.filter { !loadedTiles.contains($0) }
        guard !missing.isEmpty else { return }
        let pieces = try await store.pieces(layer: layer, tiles: range)
        for tile in missing {
            let tilePieces = pieces.filter { $0.tile == tile }
            cache[tile] = tilePieces
            loadedTiles.insert(tile)
            noteRegionAges(of: tilePieces)
        }
    }

    private func loadWatermarks() async throws {
        guard model.usesMapData, watermarks == nil else { return }
        let loaded = try await store.dataVersions(layer: layer)
        if watermarks == nil { watermarks = loaded }
    }

    private func noteRegionAges(of pieces: [DiscoveredPiece]) {
        for piece in pieces {
            let known = regionFirstDiscovered[piece.regionID] ?? piece.firstDiscovered
            regionFirstDiscovered[piece.regionID] = min(known, piece.firstDiscovered)
        }
    }

    public func snapshot() -> DiscoveredAreaSnapshot {
        DiscoveredAreaSnapshot(
            layer: layer,
            piecesByTile: cache.filter { !$0.value.isEmpty },
            maximumMarginUnits: marginUnits(atLatitude: WebMercator.maxLatitude)
        )
    }

    // MARK: Queries

    /// Whether a coordinate lies in already discovered area.
    public func isDiscovered(_ coordinate: GeoCoordinate) async throws -> Bool {
        try await region(at: coordinate) != nil
    }

    /// The region containing a coordinate, if any.
    public func region(at coordinate: GeoCoordinate) async throws -> UUID? {
        let point = WebMercator.project(coordinate)
        let tile = TileKey(containing: point, zoom: DiscoveryGrid.zoom)
        try await ensureLoaded(TileRange(zoom: tile.zoom, minX: tile.x, minY: tile.y, maxX: tile.x, maxY: tile.y))
        return cache[tile]?.first { $0.polygon.contains(point) }?.regionID
    }

    /// The layer's data watermarks (empty for models without map data).
    public func dataWatermarks() async throws -> DataVersions {
        try await loadWatermarks()
        return watermarks ?? [:]
    }

    /// Data tiles whose current data differs from the data the layer was computed
    /// from. With `fetchingMissing`, tries to obtain data for tiles that had none
    /// (e.g. downloads them when back online).
    public func staleDataTiles(fetchingMissing: Bool = false) async throws -> Set<TileKey> {
        guard model.usesMapData else { return [] }
        let marks = try await dataWatermarks()
        let missing = marks.filter { $0.value == DataGrid.noData }.keys.sorted()
        let present = marks.filter { $0.value != DataGrid.noData }.keys.sorted()
        var current = await model.currentDataVersions(of: present, fetchingMissing: false)
        current.merge(await model.currentDataVersions(of: missing, fetchingMissing: fetchingMissing)) { _, new in new }
        return Set(marks.filter { tile, version in current[tile].map { $0 != version } ?? false }.keys)
    }

    /// Computes how much new area `sample` would reveal, without changing anything.
    public func evaluate(_ sample: LocationSample) async throws -> DiscoveryEvaluation {
        let revelation = try await model.revelation(for: sample)
        let revealed = PolygonOps.union(revelation.polygons)
        var evaluation = DiscoveryEvaluation(
            sample: sample, layer: layer, revealed: revealed, revealedAreaSquareMeters: 0, newAreaSquareMeters: 0,
            dataVersions: revelation.dataVersions
        )
        guard let bounds = revealed.bounds else { return evaluation }
        let range = TileRange(covering: bounds, zoom: DiscoveryGrid.zoom)
        try await ensureLoaded(range)
        for tile in range {
            let part = PolygonOps.clip(revealed, to: tile.worldRect)
            guard !part.isEmpty else { continue }
            let scale = tile.metersPerUnit * tile.metersPerUnit
            evaluation.revealedAreaSquareMeters += area(part) * scale
            let existing = (cache[tile] ?? []).map(\.polygon)
            let remaining = existing.isEmpty ? part : PolygonOps.difference(part, existing)
            evaluation.newAreaSquareMeters += area(remaining) * scale
        }
        return evaluation
    }

    // MARK: Updates

    /// Merges the area of an evaluation into the layer and persists the change.
    /// Data tiles the sample saw for the first time get watermarks; tiles whose
    /// data differs from the watermark are reported in `staleDataTiles`.
    @discardableResult
    public func commit(_ evaluation: DiscoveryEvaluation) async throws -> DiscoveryUpdate {
        precondition(evaluation.layer == layer, "evaluation belongs to another layer")
        return try await merge(Contribution(
            sampleID: evaluation.sample.id, date: evaluation.sample.timestamp,
            components: evaluation.revealed, dataVersions: evaluation.dataVersions
        ))
    }

    /// Evaluates and commits a sample unconditionally.
    @discardableResult
    public func process(_ sample: LocationSample) async throws -> DiscoveryUpdate {
        try await commit(evaluate(sample))
    }

    /// Merges arbitrary revealed area into the layer and persists the change.
    @discardableResult
    public func merge(_ revealed: [WorldPolygon], at date: Date) async throws -> DiscoveryUpdate {
        try await merge(Contribution(sampleID: nil, date: date, components: revealed, dataVersions: [:]))
    }

    private func merge(_ contribution: Contribution) async throws -> DiscoveryUpdate {
        var contribution = contribution
        contribution.components = PolygonOps.union(contribution.components)
        if let bounds = contribution.components.bounds {
            let reach = marginUnits(atLatitude: WebMercator.unproject(bounds.center).latitude) * 2
            try await ensureLoaded(TileRange(covering: bounds.expanded(by: reach), zoom: DiscoveryGrid.zoom))
        }
        if !contribution.dataVersions.isEmpty {
            try await loadWatermarks()
        }
        // No suspension from here until the cache is updated.
        var update = integrate(contribution.components, at: contribution.date)
        if !contribution.dataVersions.isEmpty {
            var tracker = DataWatermarkTracker(watermarks: watermarks ?? [:])
            tracker.observe(contribution.dataVersions)
            watermarks = tracker.watermarks
            update.changes.append(DiscoveredAreaChangeSet(layer: layer, dataVersions: tracker.added))
            update.staleDataTiles = tracker.stale
        }
        commitLog?.append(contribution)
        try await persist(update.changes)
        return update
    }

    /// Recomputes the layer from scratch from `samples` (the discovered area is a cache).
    /// Samples are applied in chronological order; the store is replaced in one step.
    /// Returns data tiles whose data changed while rebuilding (refresh them).
    @discardableResult
    public func rebuild(from samples: [LocationSample], progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Set<TileKey> {
        await acquireExclusive()
        defer { releaseExclusive() }
        cache.removeAll()
        loadedTiles.removeAll()
        regionFirstDiscovered.removeAll()
        isFullyLoaded = true // start from an empty layer; nothing is read from the store
        let ordered = samples.sorted { ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString) }
        var tracker = DataWatermarkTracker(watermarks: [:])
        do {
            for (index, sample) in ordered.enumerated() {
                let revelation = try await model.revelation(for: sample)
                tracker.observe(revelation.dataVersions)
                _ = integrate(PolygonOps.union(revelation.polygons), at: sample.timestamp)
                progress?(index + 1, ordered.count)
            }
            watermarks = tracker.watermarks
            let (store, layer, pieces, versions) = (self.store, self.layer, cache.values.flatMap { $0 }, tracker.watermarks)
            try await persist { try await store.replaceLayer(layer, with: pieces, dataVersions: versions) }
        } catch {
            // The stored layer is unchanged; drop the partial in-memory state.
            invalidateCache()
            throw error
        }
        return tracker.stale
    }

    // MARK: Refresh after map data changed

    /// Makes the layer consistent with the current map data of `dataTiles`
    /// (docs/05-cache-invalidation.md, "DRed over the influence zone"):
    ///
    /// 1. finds the samples whose result depends on these data tiles,
    /// 2. clears the storage tiles their results can cover (plus one tile, for the
    ///    overlap margins),
    /// 3. re-derives those tiles from every sample reaching into them, in
    ///    chronological order (identical to what a full rebuild produces there),
    /// 4. recomputes the regions touching the cleared tiles: regions can merge and
    ///    split; the oldest part keeps a region's ID,
    /// 5. writes everything, including the new watermarks, as one change set.
    ///
    /// Data that changes again while refreshing is refreshed in another round.
    @discardableResult
    public func refresh(
        dataTiles: Set<TileKey>,
        locations: any LocationStore,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> DiscoveryRefresh {
        var result = DiscoveryRefresh(layer: layer)
        guard model.usesMapData, !dataTiles.isEmpty else { return result }
        await acquireExclusive()
        defer { releaseExclusive() }
        try await loadAll()
        try await loadWatermarks()
        var pending = dataTiles
        for _ in 0..<3 where !pending.isEmpty {
            let round = try await refreshRound(pending, locations: locations, progress: progress)
            result.dataTiles.formUnion(round.dataTiles)
            result.affectedSamples += round.affectedSamples
            result.recomputedSamples += round.recomputedSamples
            result.clearedTiles.formUnion(round.clearedTiles)
            result.changedTiles.formUnion(round.changedTiles)
            result.removedRegionIDs.formUnion(round.removedRegionIDs)
            result.createdRegionIDs.subtract(round.removedRegionIDs)
            result.createdRegionIDs.formUnion(round.createdRegionIDs)
            pending = round.staleDataTiles
        }
        result.staleDataTiles = pending
        return result
    }

    private func refreshRound(
        _ stale: Set<TileKey>, locations: any LocationStore, progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> DiscoveryRefresh {
        var result = DiscoveryRefresh(layer: layer)
        result.dataTiles = stale
        commitLog = []
        defer { commitLog = nil }
        let currentVersions = await model.currentDataVersions(of: stale.sorted(), fetchingMissing: false)

        // 1. Samples whose result depends on the stale data tiles.
        let candidates = try await samples(near: stale.map(\.worldRect), reach: model.maximumDataReach, in: locations)
        let affected = candidates.filter { sample in
            guard let range = model.dataTiles(for: sample) else { return false }
            return range.contains { stale.contains($0) }
        }
        result.affectedSamples = affected.count

        // 2. The storage tiles to clear: everything the affected results can cover, plus one tile.
        var cleared = Set<TileKey>()
        for sample in affected {
            guard let window = model.dataWindow(for: sample) else { continue }
            cleared.formUnion(TileRange(covering: window, zoom: DiscoveryGrid.zoom).expanded(by: 1))
        }

        // 3. Every sample whose result reaches into the cleared tiles, evaluated with the current data.
        var contributions: [Contribution] = []
        if !cleared.isEmpty {
            let pad = configuration.overlapMargin + configuration.adjacencyTolerance + 1
            let nearby = try await samples(
                near: cleared.map(\.worldRect), reach: model.maximumDataReach + pad, in: locations
            )
            let reaching = nearby.filter { sample in
                guard let window = model.dataWindow(for: sample) else { return false }
                let grow = Int64((pad / WebMercator.metersPerUnit(atLatitude: sample.latitude)).rounded(.up))
                return TileRange(covering: window.expanded(by: grow), zoom: DiscoveryGrid.zoom).contains { cleared.contains($0) }
            }.sorted { ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString) }
            for (index, sample) in reaching.enumerated() {
                let revelation = try await model.revelation(for: sample)
                contributions.append(Contribution(
                    sampleID: sample.id, date: sample.timestamp,
                    components: PolygonOps.union(revelation.polygons), dataVersions: revelation.dataVersions
                ))
                progress?(index + 1, reaching.count)
            }
            result.recomputedSamples = reaching.count
        }

        // No suspension from here until the cache is updated: results committed in
        // the meantime are included, so nothing is lost.
        let known = Set(contributions.compactMap(\.sampleID))
        for contribution in commitLog ?? [] where contribution.sampleID.map({ !known.contains($0) }) ?? true {
            contributions.append(contribution)
        }
        contributions.sort { $0.date < $1.date }

        var tracker = DataWatermarkTracker(watermarks: (watermarks ?? [:]).filter { !stale.contains($0.key) })
        var work = cache
        var removed: [DiscoveredPiece] = []
        for tile in cleared {
            removed += work[tile] ?? []
            work[tile] = nil
        }
        let placeholder = UUID()
        for contribution in contributions {
            tracker.observe(contribution.dataVersions)
            for component in contribution.components {
                rederive(component, at: contribution.date, within: cleared, regionID: placeholder, into: &work)
            }
        }
        tracker.setIfAbsent(currentVersions)
        var changes = relabelRegions(
            in: &work, cleared: cleared, removed: removed, placeholder: placeholder, result: &result
        )
        changes.append(DiscoveredAreaChangeSet(layer: layer, dataVersions: tracker.added))
        result.clearedTiles = cleared
        result.changedTiles.formUnion(cleared)
        result.staleDataTiles = tracker.stale
        cache = work.filter { !$0.value.isEmpty }
        watermarks = tracker.watermarks
        try await persist(changes)
        return result
    }

    /// Samples within `reach` metres of any of `rects`.
    private func samples(near rects: [WorldRect], reach: Double, in locations: any LocationStore) async throws -> [LocationSample] {
        var clusters: [WorldRect] = []
        for rect in rects {
            // Units per metre grow towards the poles: use the rectangle's poleward edge, plus slack.
            let metersPerUnit = min(
                WebMercator.metersPerUnit(atWorldY: Double(rect.minY)), WebMercator.metersPerUnit(atWorldY: Double(rect.maxY))
            )
            var grown = rect.expanded(by: Int64((reach * 1.05 / metersPerUnit).rounded(.up)) + 2)
            while let index = clusters.firstIndex(where: { $0.intersects(grown) }) {
                grown = grown.union(clusters.remove(at: index))
            }
            clusters.append(grown)
        }
        var seen = Set<UUID>()
        var result: [LocationSample] = []
        for cluster in clusters {
            let query = LocationQuery(tiles: TileRange(covering: cluster, zoom: DiscoveryGrid.zoom))
            for sample in try await locations.samples(matching: query) where seen.insert(sample.id).inserted {
                result.append(sample)
            }
        }
        return result
    }

    /// Merges a component into the cleared tiles of `work` exactly like `integrate`
    /// does, but without touching other tiles or deciding regions.
    private func rederive(
        _ component: WorldPolygon, at date: Date, within cleared: Set<TileKey>, regionID: UUID,
        into work: inout [TileKey: [DiscoveredPiece]]
    ) {
        let bounds = component.bounds
        let latitude = WebMercator.unproject(bounds.center).latitude
        let unitsPerMeter = 1 / WebMercator.metersPerUnit(atLatitude: latitude)
        let margin = marginUnits(atLatitude: latitude)
        let tolerance = configuration.adjacencyTolerance * unitsPerMeter
        let grown = PolygonOps.inflate([component], by: tolerance)
        let grownBounds = grown.bounds ?? bounds
        let range = TileRange(covering: bounds.expanded(by: margin + Int64(tolerance.rounded(.up))), zoom: DiscoveryGrid.zoom)
        for tile in range where cleared.contains(tile) {
            let part = PolygonOps.clip([component], to: tile.worldRect.expanded(by: margin))
            guard !part.isEmpty else { continue }
            let pieces = work[tile] ?? []
            let old = pieces.filter { piece in
                piece.polygon.bounds.intersects(grownBounds) && PolygonOps.intersects([piece.polygon], grown)
            }
            let oldIDs = Set(old.map(\.id))
            work[tile] = pieces.filter { !oldIDs.contains($0.id) }
                + mergedPieces(part, with: old, in: tile, at: date, regionID: regionID, unitsPerMeter: unitsPerMeter)
        }
    }

    /// Recomputes the connected components of everything connected to the cleared
    /// tiles and labels them: the oldest component claiming a region keeps its ID
    /// (claims: surviving pieces, or new area overlapping removed pieces of the
    /// region); other components get new IDs. Returns the change set (without
    /// watermarks) and updates `work` and the region ages.
    private func relabelRegions(
        in work: inout [TileKey: [DiscoveredPiece]], cleared: Set<TileKey>, removed: [DiscoveredPiece],
        placeholder: UUID, result: inout DiscoveryRefresh
    ) -> DiscoveredAreaChangeSet {
        let oldRegions = Set(removed.map(\.regionID))
        var changes = DiscoveredAreaChangeSet(layer: layer, removedPieceIDs: removed.map(\.id))

        // Nodes: new pieces, surviving pieces of affected regions, and pieces of other
        // regions next to them (each other region is connected, so it is one node).
        struct Node { var tile: TileKey; var index: Int; var piece: DiscoveredPiece }
        var nodes: [Node] = []
        var nodeIndex: [UUID: Int] = [:]
        func addNode(_ tile: TileKey, _ index: Int, _ piece: DiscoveredPiece) -> Int {
            if let existing = nodeIndex[piece.id] { return existing }
            nodes.append(Node(tile: tile, index: index, piece: piece))
            nodeIndex[piece.id] = nodes.count - 1
            return nodes.count - 1
        }
        func isMovable(_ piece: DiscoveredPiece) -> Bool {
            piece.regionID == placeholder || oldRegions.contains(piece.regionID)
        }
        for (tile, pieces) in work {
            for (index, piece) in pieces.enumerated() where isMovable(piece) {
                _ = addNode(tile, index, piece)
            }
        }
        let movableCount = nodes.count
        var parent = Array(0..<movableCount)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func unite(_ a: Int, _ b: Int) {
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var foreignRepresentative: [UUID: Int] = [:]
        var inflated: [Int: [WorldPolygon]] = [:]
        for i in 0..<movableCount {
            let node = nodes[i]
            let unitsPerMeter = 1 / node.tile.metersPerUnit
            let tolerance = configuration.adjacencyTolerance * unitsPerMeter
            let reach = node.piece.polygon.bounds.expanded(by: Int64(tolerance.rounded(.up)) + 1)
            for dy in -1...1 {
                for dx in -1...1 {
                    let neighbour = TileKey(zoom: node.tile.zoom, x: node.tile.x + dx, y: node.tile.y + dy)
                    for (index, other) in (work[neighbour] ?? []).enumerated() where other.id != node.piece.id {
                        guard reach.intersects(other.polygon.bounds) else { continue }
                        let j: Int
                        if isMovable(other) {
                            j = nodeIndex[other.id]!
                            if j < i || find(i) == find(j) { continue }
                        } else {
                            j = addNode(neighbour, index, other)
                            if j >= parent.count { parent.append(j) }
                            if let representative = foreignRepresentative[other.regionID] {
                                unite(j, representative)
                            } else {
                                foreignRepresentative[other.regionID] = j
                            }
                            if find(i) == find(j) { continue }
                        }
                        let grown = inflated[i] ?? PolygonOps.inflate([node.piece.polygon], by: tolerance)
                        inflated[i] = grown
                        if PolygonOps.intersects([other.polygon], grown) { unite(i, j) }
                    }
                }
            }
        }

        // Components and their claims.
        var members: [Int: [Int]] = [:]
        for i in 0..<nodes.count { members[find(i), default: []].append(i) }
        let removedByTile = Dictionary(grouping: removed, by: \.tile)
        struct Component { var nodes: [Int]; var age: Date; var key: String; var claims: [UUID] }
        var components: [Component] = []
        for (_, indices) in members {
            var age = Date.distantFuture
            var claims = Set<UUID>()
            for i in indices {
                let piece = nodes[i].piece
                if isMovable(piece) {
                    age = min(age, piece.firstDiscovered)
                    if piece.regionID != placeholder {
                        claims.insert(piece.regionID)
                    } else {
                        for old in removedByTile[nodes[i].tile] ?? []
                        where old.polygon.bounds.intersects(piece.polygon.bounds)
                            && PolygonOps.intersects([old.polygon], [piece.polygon]) {
                            claims.insert(old.regionID)
                        }
                    }
                } else {
                    age = min(age, regionFirstDiscovered[piece.regionID] ?? piece.firstDiscovered)
                    claims.insert(piece.regionID)
                }
            }
            let key = indices.map { nodes[$0].piece.id.uuidString }.min() ?? ""
            let ordered = claims.sorted {
                (regionFirstDiscovered[$0] ?? .distantFuture, $0.uuidString) < (regionFirstDiscovered[$1] ?? .distantFuture, $1.uuidString)
            }
            components.append(Component(nodes: indices, age: age, key: key, claims: ordered))
        }
        components.sort { ($0.age, $0.key) < ($1.age, $1.key) }

        // Labels: the oldest component claiming a region keeps its ID.
        var taken = Set<UUID>()
        var merges: [UUID: [UUID]] = [:]
        var upserts: [DiscoveredPiece] = []
        var survivingRegions = Set<UUID>()
        var ages: [UUID: Date] = [:]
        for component in components {
            let label = component.claims.first { !taken.contains($0) } ?? UUID()
            taken.insert(label)
            survivingRegions.insert(label)
            ages[label] = component.age
            if !component.claims.contains(label) { result.createdRegionIDs.insert(label) }
            for i in component.nodes {
                let node = nodes[i]
                if isMovable(node.piece) {
                    guard node.piece.regionID != label || cleared.contains(node.tile) else { continue }
                    var piece = node.piece
                    piece.regionID = label
                    work[node.tile]![node.index] = piece
                    upserts.append(piece)
                    result.changedTiles.insert(node.tile)
                } else if node.piece.regionID != label, !(merges[label] ?? []).contains(node.piece.regionID) {
                    merges[label, default: []].append(node.piece.regionID)
                }
            }
        }
        for (target, sources) in merges.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let merge = DiscoveredAreaChangeSet.RegionMerge(sources: sources.sorted { $0.uuidString < $1.uuidString }, target: target)
            relabel(merge, in: &work, changedTiles: &result.changedTiles)
            changes.regionMerges.append(merge)
            survivingRegions.subtract(sources)
            result.removedRegionIDs.formUnion(sources)
        }
        changes.upsertedPieces = upserts
        for region in oldRegions where !survivingRegions.contains(region) {
            result.removedRegionIDs.insert(region)
            regionFirstDiscovered[region] = nil
        }
        for region in result.removedRegionIDs { regionFirstDiscovered[region] = nil }
        for (label, age) in ages where survivingRegions.contains(label) {
            regionFirstDiscovered[label] = age
        }
        return changes
    }

    // MARK: Store writes

    private func persist(_ changes: DiscoveredAreaChangeSet) async throws {
        let store = self.store
        try await persist { try await store.apply(changes) }
    }

    /// Runs a store write after all earlier ones (the task is created before any suspension).
    private func persist(_ write: @escaping @Sendable () async throws -> Void) async throws {
        let previous = lastWrite
        let task = Task {
            _ = await previous?.result
            try await write()
        }
        lastWrite = task
        try await task.value
    }

    // MARK: Exclusive operations

    private func acquireExclusive() async {
        while isExclusive {
            await withCheckedContinuation { exclusiveWaiters.append($0) }
        }
        isExclusive = true
    }

    private func releaseExclusive() {
        isExclusive = false
        if !exclusiveWaiters.isEmpty { exclusiveWaiters.removeFirst().resume() }
    }

    // MARK: Algorithm

    /// Merges connected components into the cache and returns the corresponding change set.
    /// All tiles that may be touched must be loaded.
    private func integrate(_ components: [WorldPolygon], at date: Date) -> DiscoveryUpdate {
        var update = DiscoveryUpdate(
            layer: layer, changedTiles: [], regionIDs: [], mergedRegionIDs: [],
            changes: DiscoveredAreaChangeSet(layer: layer)
        )
        for component in components {
            integrate(component, at: date, into: &update)
        }
        return update
    }

    private func integrate(_ component: WorldPolygon, at date: Date, into update: inout DiscoveryUpdate) {
        let bounds = component.bounds
        let latitude = WebMercator.unproject(bounds.center).latitude
        let unitsPerMeter = 1 / WebMercator.metersPerUnit(atLatitude: latitude)
        let margin = marginUnits(atLatitude: latitude)
        let tolerance = configuration.adjacencyTolerance * unitsPerMeter

        // 1. Find every existing piece within the adjacency tolerance.
        let grown = PolygonOps.inflate([component], by: tolerance)
        let grownBounds = grown.bounds ?? bounds
        let range = TileRange(covering: bounds.expanded(by: margin + Int64(tolerance.rounded(.up))), zoom: DiscoveryGrid.zoom)
        var touching: [TileKey: [DiscoveredPiece]] = [:]
        for tile in range {
            guard let pieces = cache[tile] else { continue }
            let hits = pieces.filter { piece in
                piece.polygon.bounds.intersects(grownBounds) && PolygonOps.intersects([piece.polygon], grown)
            }
            if !hits.isEmpty { touching[tile] = hits }
        }

        // 2. Decide the region: a new one, or the oldest touched region absorbs the others.
        let touchedPieces = touching.values.flatMap { $0 }
        var regionAge: [UUID: Date] = [:]
        for piece in touchedPieces {
            let fallback = min(regionAge[piece.regionID] ?? piece.firstDiscovered, piece.firstDiscovered)
            regionAge[piece.regionID] = regionFirstDiscovered[piece.regionID].map { min($0, fallback) } ?? fallback
        }
        let target = regionAge.min { ($0.value, $0.key.uuidString) < ($1.value, $1.key.uuidString) }?.key ?? UUID()
        let absorbed = regionAge.keys.filter { $0 != target }.sorted { $0.uuidString < $1.uuidString }
        let targetAge = ([regionAge[target], regionFirstDiscovered[target], date].compactMap { $0 }).min() ?? date
        regionFirstDiscovered[target] = absorbed.compactMap { regionFirstDiscovered[$0] }.reduce(targetAge, min)
        for id in absorbed { regionFirstDiscovered[id] = nil }
        if !absorbed.isEmpty {
            let merge = DiscoveredAreaChangeSet.RegionMerge(sources: absorbed, target: target)
            relabel(merge, in: &cache, changedTiles: &update.changedTiles)
            update.changes.append(DiscoveredAreaChangeSet(layer: layer, regionMerges: [merge]))
            update.mergedRegionIDs += absorbed
            // Pieces collected above still carry their old labels; the store relabels them anyway.
            for (tile, pieces) in touching {
                touching[tile] = pieces.map { piece in
                    var piece = piece
                    piece.regionID = target
                    return piece
                }
            }
        }
        if !update.regionIDs.contains(target) { update.regionIDs.append(target) }

        // 3. Union the component with the touching pieces, tile by tile.
        for tile in range {
            let part = PolygonOps.clip([component], to: tile.worldRect.expanded(by: margin))
            guard !part.isEmpty else { continue }
            let old = touching[tile] ?? []
            let newPieces = mergedPieces(part, with: old, in: tile, at: date, regionID: target, unitsPerMeter: unitsPerMeter)
            let oldIDs = Set(old.map(\.id))
            cache[tile] = (cache[tile] ?? []).filter { !oldIDs.contains($0.id) } + newPieces
            update.changes.append(DiscoveredAreaChangeSet(layer: layer, removedPieceIDs: Array(oldIDs), upsertedPieces: newPieces))
            update.changedTiles.insert(tile)
        }
    }

    /// The pieces of `tile` after uniting `part` with the touching pieces `old`.
    private func mergedPieces(
        _ part: [WorldPolygon], with old: [DiscoveredPiece], in tile: TileKey, at date: Date, regionID: UUID,
        unitsPerMeter: Double
    ) -> [DiscoveredPiece] {
        var merged = PolygonOps.union(part + old.map(\.polygon))
        if configuration.simplificationTolerance > 0 {
            merged = PolygonOps.simplify(merged, epsilon: configuration.simplificationTolerance * unitsPerMeter)
        }
        // Simplification may pull bounds inwards by up to its tolerance.
        let slack = Int64((configuration.simplificationTolerance * unitsPerMeter).rounded(.up)) + 1
        return merged.map { polygon in
            let searchBounds = polygon.bounds.expanded(by: slack)
            let contributors = old.filter { searchBounds.contains($0.polygon.bounds) }
            let first = contributors.map(\.firstDiscovered).min().map { min($0, date) } ?? date
            return DiscoveredPiece(
                layer: layer, regionID: regionID, tile: tile, polygon: polygon,
                areaSquareMeters: areaInsideTile(polygon, tile: tile),
                firstDiscovered: first, lastUpdated: date
            )
        }
    }

    /// Applies a region merge to all pieces of `pieces`.
    private func relabel(
        _ merge: DiscoveredAreaChangeSet.RegionMerge, in pieces: inout [TileKey: [DiscoveredPiece]],
        changedTiles: inout Set<TileKey>
    ) {
        let sources = Set(merge.sources)
        for (tile, tilePieces) in pieces where tilePieces.contains(where: { sources.contains($0.regionID) }) {
            pieces[tile] = tilePieces.map { piece in
                guard sources.contains(piece.regionID) else { return piece }
                var piece = piece
                piece.regionID = merge.target
                return piece
            }
            changedTiles.insert(tile)
        }
    }

    // MARK: Helpers

    private func marginUnits(atLatitude latitude: Double) -> Int64 {
        Int64((configuration.overlapMargin / WebMercator.metersPerUnit(atLatitude: latitude)).rounded(.up))
    }

    private func areaInsideTile(_ polygon: WorldPolygon, tile: TileKey) -> Double {
        let rect = tile.worldRect
        let inside = rect.contains(polygon.bounds) ? [polygon] : PolygonOps.clip([polygon], to: rect)
        return area(inside) * tile.metersPerUnit * tile.metersPerUnit
    }

    private func area(_ polygons: [WorldPolygon]) -> Double {
        polygons.reduce(0) { $0 + $1.area }
    }
}
