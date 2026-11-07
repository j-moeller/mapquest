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
/// (connected components) up to date, and rebuilds the layer from samples.
///
/// See docs/02-architecture.md ("Discovered area") for the algorithm.
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

    /// Computes how much new area `sample` would reveal, without changing anything.
    public func evaluate(_ sample: LocationSample) async throws -> DiscoveryEvaluation {
        let revealed = PolygonOps.union(try await model.revealedArea(for: sample))
        var evaluation = DiscoveryEvaluation(
            sample: sample, layer: layer, revealed: revealed, revealedAreaSquareMeters: 0, newAreaSquareMeters: 0
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
    @discardableResult
    public func commit(_ evaluation: DiscoveryEvaluation) async throws -> DiscoveryUpdate {
        precondition(evaluation.layer == layer, "evaluation belongs to another layer")
        return try await merge(evaluation.revealed, at: evaluation.sample.timestamp)
    }

    /// Evaluates and commits a sample unconditionally.
    @discardableResult
    public func process(_ sample: LocationSample) async throws -> DiscoveryUpdate {
        try await commit(evaluate(sample))
    }

    /// Merges arbitrary revealed area into the layer and persists the change.
    @discardableResult
    public func merge(_ revealed: [WorldPolygon], at date: Date) async throws -> DiscoveryUpdate {
        let components = PolygonOps.union(revealed)
        if let bounds = components.bounds {
            let reach = marginUnits(atLatitude: WebMercator.unproject(bounds.center).latitude) * 2
            try await ensureLoaded(TileRange(covering: bounds.expanded(by: reach), zoom: DiscoveryGrid.zoom))
        }
        let update = integrate(components, at: date)
        try await store.apply(update.changes)
        return update
    }

    /// Recomputes the layer from scratch from `samples` (the discovered area is a cache).
    /// Samples are applied in chronological order; the store is replaced in one step.
    public func rebuild(from samples: [LocationSample], progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        cache.removeAll()
        loadedTiles.removeAll()
        regionFirstDiscovered.removeAll()
        isFullyLoaded = true // start from an empty layer; nothing is read from the store
        let ordered = samples.sorted { ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString) }
        do {
            for (index, sample) in ordered.enumerated() {
                let revealed = PolygonOps.union(try await model.revealedArea(for: sample))
                _ = integrate(revealed, at: sample.timestamp)
                progress?(index + 1, ordered.count)
            }
            try await store.replaceLayer(layer, with: cache.values.flatMap { $0 })
        } catch {
            // The stored layer is unchanged; drop the partial in-memory state.
            invalidateCache()
            throw error
        }
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
            relabel(merge, changedTiles: &update.changedTiles)
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
            let clipRect = tile.worldRect.expanded(by: margin)
            let part = PolygonOps.clip([component], to: clipRect)
            guard !part.isEmpty else { continue }
            let old = touching[tile] ?? []
            var merged = PolygonOps.union(part + old.map(\.polygon))
            if configuration.simplificationTolerance > 0 {
                merged = PolygonOps.simplify(merged, epsilon: configuration.simplificationTolerance * unitsPerMeter)
            }
            // Simplification may pull bounds inwards by up to its tolerance.
            let slack = Int64((configuration.simplificationTolerance * unitsPerMeter).rounded(.up)) + 1
            var newPieces: [DiscoveredPiece] = []
            for polygon in merged {
                let searchBounds = polygon.bounds.expanded(by: slack)
                let contributors = old.filter { searchBounds.contains($0.polygon.bounds) }
                let first = contributors.map(\.firstDiscovered).min().map { min($0, date) } ?? date
                newPieces.append(DiscoveredPiece(
                    layer: layer, regionID: target, tile: tile, polygon: polygon,
                    areaSquareMeters: areaInsideTile(polygon, tile: tile),
                    firstDiscovered: first, lastUpdated: date
                ))
            }
            let oldIDs = Set(old.map(\.id))
            cache[tile] = (cache[tile] ?? []).filter { !oldIDs.contains($0.id) } + newPieces
            update.changes.append(DiscoveredAreaChangeSet(layer: layer, removedPieceIDs: Array(oldIDs), upsertedPieces: newPieces))
            update.changedTiles.insert(tile)
        }
    }

    /// Applies a region merge to all cached pieces.
    private func relabel(_ merge: DiscoveredAreaChangeSet.RegionMerge, changedTiles: inout Set<TileKey>) {
        let sources = Set(merge.sources)
        for (tile, pieces) in cache where pieces.contains(where: { sources.contains($0.regionID) }) {
            cache[tile] = pieces.map { piece in
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
