import Foundation

/// A volatile `MapQuestDataStore`, used for tests, previews and as a staging
/// area when rebuilding discovered area.
public actor InMemoryDataStore: MapQuestDataStore {
    public nonisolated let descriptor: DataSourceDescriptor

    private var samplesByID: [UUID: LocationSample] = [:]
    private var piecesByLayer: [DiscoveryLayerID: [UUID: DiscoveredPiece]] = [:]
    private var watermarksByLayer: [DiscoveryLayerID: DataVersions] = [:]
    private var segmentsByID: [UUID: TrackSegment] = [:]

    public init(descriptor: DataSourceDescriptor = DataSourceDescriptor(id: "memory", displayName: "In memory", kind: .inMemory)) {
        self.descriptor = descriptor
    }

    // MARK: LocationStore

    public func addSamples(_ samples: [LocationSample]) {
        for sample in samples {
            samplesByID[sample.id] = sample
        }
    }

    public func samples(matching query: LocationQuery) -> [LocationSample] {
        var result = samplesByID.values.filter(query.matches)
        switch query.order {
        case .chronological:
            result.sort { ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString) }
        case .reverseChronological:
            result.sort { ($0.timestamp, $0.id.uuidString) > ($1.timestamp, $1.id.uuidString) }
        }
        if let limit = query.limit, result.count > limit {
            result = Array(result.prefix(limit))
        }
        return result
    }

    public func sampleCount() -> Int { samplesByID.count }

    public func removeAllSamples() { samplesByID.removeAll() }

    // MARK: DiscoveredAreaStore

    public func pieces(layer: DiscoveryLayerID, tiles: TileRange?) -> [DiscoveredPiece] {
        let all = Array((piecesByLayer[layer] ?? [:]).values)
        let filtered = tiles.map { range in all.filter { range.contains($0.tile) } } ?? all
        return filtered.sorted { ($0.tile, $0.id.uuidString) < ($1.tile, $1.id.uuidString) }
    }

    public func apply(_ changes: DiscoveredAreaChangeSet) {
        var layerPieces = piecesByLayer[changes.layer] ?? [:]
        for merge in changes.regionMerges {
            let sources = Set(merge.sources)
            for (id, piece) in layerPieces where sources.contains(piece.regionID) {
                layerPieces[id]?.regionID = merge.target
            }
        }
        for id in changes.removedPieceIDs {
            layerPieces[id] = nil
        }
        for piece in changes.upsertedPieces {
            precondition(piece.layer == changes.layer, "piece layer does not match change set layer")
            layerPieces[piece.id] = piece
        }
        piecesByLayer[changes.layer] = layerPieces.isEmpty ? nil : layerPieces
        if !changes.dataVersions.isEmpty {
            watermarksByLayer[changes.layer, default: [:]].merge(changes.dataVersions) { _, new in new }
        }
    }

    public func removeAllPieces(layer: DiscoveryLayerID) {
        piecesByLayer[layer] = nil
        watermarksByLayer[layer] = nil
    }

    public func dataVersions(layer: DiscoveryLayerID) -> DataVersions {
        watermarksByLayer[layer] ?? [:]
    }

    public func layers() -> [DiscoveryLayerID] {
        piecesByLayer.keys.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: TrackStore

    public func putTrackSegments(_ segments: [TrackSegment]) {
        for segment in segments { segmentsByID[segment.id] = segment }
    }

    public func trackSegments(overlapping interval: DateInterval?, intersecting rect: WorldRect?) -> [TrackSegment] {
        segmentsByID.values.filter { segment in
            if let interval, segment.end < interval.start || segment.start > interval.end { return false }
            if let rect, !segment.bounds.intersects(rect) { return false }
            return true
        }.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
    }

    public func trackSummary() -> TrackSummary {
        let segments = segmentsByID.values
        return TrackSummary(
            segmentCount: segments.count,
            pointCount: segments.reduce(0) { $0 + $1.pointCount },
            byteCount: segments.reduce(0) { $0 + $1.data.count },
            first: segments.map(\.start).min(),
            last: segments.map(\.end).max()
        )
    }

    public func removeAllTrack() {
        segmentsByID.removeAll()
    }
}
