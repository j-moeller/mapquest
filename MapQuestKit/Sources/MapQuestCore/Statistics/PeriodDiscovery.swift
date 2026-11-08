import Foundation

/// The area revealed during one period, and the figures behind it.
public struct PeriodArea: Sendable {
    public var period: Period
    public var layer: DiscoveryLayerID
    /// Geometry of the area (one region per piece group; regions are not tracked).
    public var snapshot: DiscoveredAreaSnapshot
    public var statistics: TrackStatistics
    /// Statistics per active day (for charts).
    public var days: [(day: Period, statistics: TrackStatistics)]
    /// Fixes the area was computed from after sampling.
    public var evaluatedFixes: Int
}

/// Time-based views: the area revealed by the track of a day, week, month or year.
///
/// The area of a day is computed from that day's track, reduced by the
/// `CoverageSampler` (revisits merged), with any discovery model. Completed days
/// are kept as cache layers in the data store (`<layer>@day:<date>:s<spacing>`,
/// with data watermarks, so new building data invalidates them); the current day
/// is recomputed when its track grew. Longer periods are the union of their days.
public actor PeriodDiscovery {
    public nonisolated let store: any MapQuestDataStore
    public nonisolated let calendar: Calendar
    private let now: @Sendable () -> Date
    /// Results of days that are not complete yet, by layer key, with the track length they used.
    private var openDays: [DiscoveryLayerID: (area: PeriodArea, trackFixes: Int)] = [:]

    public init(store: any MapQuestDataStore, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.calendar = calendar
        self.now = now
    }

    /// The layer ID under which a completed day is cached.
    public nonisolated func dayLayer(_ day: Period, model: any DiscoveryModel, sampling: CoverageSampler.Configuration) -> DiscoveryLayerID {
        DiscoveryLayerID("\(model.layer.rawValue)@day:\(day.key(calendar: calendar)):s\(Int(sampling.spacing.rounded()))")
    }

    /// The area and statistics of a period. `progress` reports days done / days to compute.
    public func area(
        of period: Period, model: any DiscoveryModel, sampling: CoverageSampler.Configuration = .init(),
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> PeriodArea {
        let segments = try await store.trackSegments(overlapping: DateInterval(start: period.start, end: period.end), intersecting: nil)
        let days = period.days(calendar: calendar).filter { day in
            segments.contains { $0.end >= day.start && $0.start < day.end }
        }
        var areas: [PeriodArea] = []
        for (index, day) in days.enumerated() {
            areas.append(try await dayArea(day, model: model, sampling: sampling))
            progress?(index + 1, days.count)
        }
        if period.kind == .day {
            return areas.first ?? PeriodArea(
                period: period, layer: model.layer, snapshot: .empty(layer: model.layer), statistics: TrackStatistics(),
                days: [], evaluatedFixes: 0
            )
        }
        return PeriodArea(
            period: period, layer: model.layer,
            snapshot: Self.union(areas.map(\.snapshot), layer: model.layer),
            statistics: TrackStatistics.combined(areas.map(\.statistics)),
            days: areas.map { ($0.period, $0.statistics) },
            evaluatedFixes: areas.reduce(0) { $0 + $1.evaluatedFixes }
        )
    }

    /// Statistics only (no area): fast, for charts and summaries.
    public func statistics(of period: Period) async throws -> (total: TrackStatistics, days: [(day: Period, statistics: TrackStatistics)]) {
        let points = try await store.trackPoints(in: DateInterval(start: period.start, end: period.end)).filter { period.contains($0.timestamp) }
        var days: [(Period, TrackStatistics)] = []
        var index = 0
        while index < points.count {
            let day = Period(.day, containing: points[index].timestamp, calendar: calendar)
            var next = index
            while next < points.count, day.contains(points[next].timestamp) { next += 1 }
            days.append((day, TrackStatistics.of(Array(points[index..<next]), calendar: calendar)))
            index = next
        }
        return (TrackStatistics.combined(days.map(\.1)), days)
    }

    private func dayArea(_ day: Period, model: any DiscoveryModel, sampling: CoverageSampler.Configuration) async throws -> PeriodArea {
        let layer = dayLayer(day, model: model, sampling: sampling)
        let complete = day.end <= now()
        let points = try await store.trackPoints(in: DateInterval(start: day.start, end: day.end)).filter { day.contains($0.timestamp) }
        let statistics = TrackStatistics.of(points, calendar: calendar)

        if complete, let cached = try await cachedDay(layer, model: model) {
            return PeriodArea(period: day, layer: model.layer, snapshot: cached, statistics: statistics, days: [(day, statistics)], evaluatedFixes: 0)
        }
        if !complete, let open = openDays[layer], open.trackFixes == points.count {
            return open.area
        }

        let samples = CoverageSampler.reduce(points.map(\.sample), configuration: sampling.offline)
        let scratch = InMemoryDataStore()
        let engine = DiscoveryEngine(model: model, store: scratch)
        try await engine.rebuild(from: samples)
        let snapshot = await engine.snapshot()
        let area = PeriodArea(period: day, layer: model.layer, snapshot: snapshot, statistics: statistics, days: [(day, statistics)], evaluatedFixes: samples.count)
        if complete {
            let pieces = snapshot.piecesByTile.values.flatMap { $0 }.map { piece -> DiscoveredPiece in
                var piece = piece
                piece.layer = layer
                return piece
            }
            let versions = try await scratch.dataVersions(layer: model.layer)
            try await store.replaceLayer(layer, with: pieces, dataVersions: versions)
            openDays[layer] = nil
        } else {
            openDays[layer] = (area, points.count)
        }
        return area
    }

    /// A cached completed day, unless its map data changed since.
    private func cachedDay(_ layer: DiscoveryLayerID, model: any DiscoveryModel) async throws -> DiscoveredAreaSnapshot? {
        let pieces = try await store.pieces(layer: layer, tiles: nil)
        guard !pieces.isEmpty else { return nil }
        if model.usesMapData {
            let marks = try await store.dataVersions(layer: layer)
            let current = await model.currentDataVersions(of: Array(marks.keys), fetchingMissing: false)
            guard marks.allSatisfy({ current[$0.key] == nil || current[$0.key] == $0.value }) else { return nil }
        }
        return DiscoveredAreaSnapshot(
            layer: layer, piecesByTile: Dictionary(grouping: pieces, by: \.tile),
            maximumMarginUnits: Self.marginUnits
        )
    }

    /// Deletes cached days of layers other than `keeping` (e.g. after parameters changed).
    public func deleteCachedDays(keeping layers: Set<DiscoveryLayerID>) async throws {
        for layer in try await store.layers() where layer.rawValue.contains("@day:") {
            let base = DiscoveryLayerID(String(layer.rawValue.prefix { $0 != "@" }))
            if !layers.contains(base) { try await store.removeAllPieces(layer: layer) }
        }
        openDays.removeAll()
    }

    // MARK: Union of days

    private static let marginUnits = Int64((2 / WebMercator.metersPerUnit(atLatitude: WebMercator.maxLatitude)).rounded(.up))

    /// Per-tile union of several areas (the pieces of all inputs share the tile grid and margins).
    public static func union(_ snapshots: [DiscoveredAreaSnapshot], layer: DiscoveryLayerID) -> DiscoveredAreaSnapshot {
        guard snapshots.count > 1 else {
            return snapshots.first.map { DiscoveredAreaSnapshot(layer: layer, piecesByTile: $0.piecesByTile, maximumMarginUnits: $0.maximumMarginUnits) }
                ?? .empty(layer: layer)
        }
        var byTile: [TileKey: [DiscoveredPiece]] = [:]
        for snapshot in snapshots {
            for (tile, pieces) in snapshot.piecesByTile { byTile[tile, default: []] += pieces }
        }
        let region = UUID()
        var result: [TileKey: [DiscoveredPiece]] = [:]
        for (tile, pieces) in byTile {
            let first = pieces.map(\.firstDiscovered).min() ?? Date()
            let last = pieces.map(\.lastUpdated).max() ?? first
            let polygons = pieces.count == 1 ? [pieces[0].polygon] : PolygonOps.union(pieces.map(\.polygon))
            result[tile] = polygons.map { polygon in
                let rect = tile.worldRect
                let inside = rect.contains(polygon.bounds) ? [polygon] : PolygonOps.clip([polygon], to: rect)
                let area = inside.reduce(0) { $0 + $1.area } * tile.metersPerUnit * tile.metersPerUnit
                return DiscoveredPiece(
                    layer: layer, regionID: region, tile: tile, polygon: polygon, areaSquareMeters: area,
                    firstDiscovered: first, lastUpdated: last
                )
            }
        }
        let margin = snapshots.map(\.maximumMarginUnits).max() ?? marginUnits
        return DiscoveredAreaSnapshot(layer: layer, piecesByTile: result, maximumMarginUnits: margin)
    }
}
