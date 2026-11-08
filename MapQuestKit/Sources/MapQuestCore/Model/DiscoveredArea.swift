import Foundation

/// Identifies one *layer* of discovered area. Each discovery model (2D circle,
/// 3D viewshed, …) writes its own layer; all layers are caches derived from the
/// same location samples and can be rebuilt independently.
public struct DiscoveryLayerID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
}

/// One connected polygon (with holes) of discovered area inside one storage tile.
///
/// The discovered area of a layer is the union of all its pieces. Pieces are
/// clipped to their tile grown by a small overlap margin, so pieces of
/// neighbouring tiles overlap slightly (seamless rendering, adjacency detection
/// across tile borders). `areaSquareMeters` only counts the part inside the
/// exact tile so that sums over pieces are not inflated by the margins.
public struct DiscoveredPiece: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var layer: DiscoveryLayerID
    /// The connected region (component) this piece belongs to.
    public var regionID: UUID
    public var tile: TileKey
    public var polygon: WorldPolygon
    public var areaSquareMeters: Double
    /// When any part of this piece was discovered first.
    public var firstDiscovered: Date
    /// When this piece last grew.
    public var lastUpdated: Date

    public init(
        id: UUID = UUID(),
        layer: DiscoveryLayerID,
        regionID: UUID,
        tile: TileKey,
        polygon: WorldPolygon,
        areaSquareMeters: Double,
        firstDiscovered: Date,
        lastUpdated: Date
    ) {
        self.id = id
        self.layer = layer
        self.regionID = regionID
        self.tile = tile
        self.polygon = polygon
        self.areaSquareMeters = areaSquareMeters
        self.firstDiscovered = firstDiscovered
        self.lastUpdated = lastUpdated
    }
}

/// A connected component of discovered area: all pieces that are (transitively)
/// adjacent or overlapping. Disconnected areas – another city, another district
/// reached with the phone switched off – form separate regions.
public struct DiscoveredRegion: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var layer: DiscoveryLayerID
    public var areaSquareMeters: Double
    public var pieceCount: Int
    public var firstDiscovered: Date
    public var lastUpdated: Date
    /// Storage tiles touched by the region (bounding range).
    public var tiles: TileRange

    public init(
        id: UUID, layer: DiscoveryLayerID, areaSquareMeters: Double, pieceCount: Int,
        firstDiscovered: Date, lastUpdated: Date, tiles: TileRange
    ) {
        self.id = id
        self.layer = layer
        self.areaSquareMeters = areaSquareMeters
        self.pieceCount = pieceCount
        self.firstDiscovered = firstDiscovered
        self.lastUpdated = lastUpdated
        self.tiles = tiles
    }

    /// Aggregates pieces into regions.
    public static func aggregate(_ pieces: [DiscoveredPiece]) -> [DiscoveredRegion] {
        var regions: [UUID: DiscoveredRegion] = [:]
        for piece in pieces {
            if var region = regions[piece.regionID] {
                region.areaSquareMeters += piece.areaSquareMeters
                region.pieceCount += 1
                region.firstDiscovered = min(region.firstDiscovered, piece.firstDiscovered)
                region.lastUpdated = max(region.lastUpdated, piece.lastUpdated)
                region.tiles.minX = min(region.tiles.minX, piece.tile.x)
                region.tiles.minY = min(region.tiles.minY, piece.tile.y)
                region.tiles.maxX = max(region.tiles.maxX, piece.tile.x)
                region.tiles.maxY = max(region.tiles.maxY, piece.tile.y)
                regions[piece.regionID] = region
            } else {
                regions[piece.regionID] = DiscoveredRegion(
                    id: piece.regionID, layer: piece.layer, areaSquareMeters: piece.areaSquareMeters,
                    pieceCount: 1, firstDiscovered: piece.firstDiscovered, lastUpdated: piece.lastUpdated,
                    tiles: TileRange(
                        zoom: piece.tile.zoom, minX: piece.tile.x, minY: piece.tile.y,
                        maxX: piece.tile.x, maxY: piece.tile.y
                    )
                )
            }
        }
        return regions.values.sorted { ($0.firstDiscovered, $0.id.uuidString) < ($1.firstDiscovered, $1.id.uuidString) }
    }
}

/// An atomic modification of one layer of discovered area.
///
/// Stores apply the parts in this order: region merges, piece removals, piece
/// upserts, data watermarks. A remote store can send the whole change set as one
/// request.
public struct DiscoveredAreaChangeSet: Hashable, Sendable {
    /// Relabels all pieces of `sources` to `target`.
    public struct RegionMerge: Hashable, Sendable {
        public var sources: [UUID]
        public var target: UUID

        public init(sources: [UUID], target: UUID) {
            self.sources = sources
            self.target = target
        }
    }

    public var layer: DiscoveryLayerID
    public var regionMerges: [RegionMerge]
    public var removedPieceIDs: [UUID]
    public var upsertedPieces: [DiscoveredPiece]
    /// Data watermarks to set: the version of each data tile the layer is now
    /// consistent with (docs/05-cache-invalidation.md).
    public var dataVersions: DataVersions

    public init(
        layer: DiscoveryLayerID,
        regionMerges: [RegionMerge] = [],
        removedPieceIDs: [UUID] = [],
        upsertedPieces: [DiscoveredPiece] = [],
        dataVersions: DataVersions = [:]
    ) {
        self.layer = layer
        self.regionMerges = regionMerges
        self.removedPieceIDs = removedPieceIDs
        self.upsertedPieces = upsertedPieces
        self.dataVersions = dataVersions
    }

    public var isEmpty: Bool {
        regionMerges.isEmpty && removedPieceIDs.isEmpty && upsertedPieces.isEmpty && dataVersions.isEmpty
    }

    /// Combines `self` followed by `other` into one change set with the same effect
    /// as applying both in sequence (piece IDs are never reused after removal).
    public mutating func append(_ other: DiscoveredAreaChangeSet) {
        precondition(other.layer == layer, "cannot combine change sets of different layers")
        // Merges of `other` must also relabel pieces that `self` upserts, because
        // stores apply all merges before any upsert.
        for merge in other.regionMerges {
            let sources = Set(merge.sources)
            for index in upsertedPieces.indices where sources.contains(upsertedPieces[index].regionID) {
                upsertedPieces[index].regionID = merge.target
            }
        }
        regionMerges += other.regionMerges
        let removed = Set(other.removedPieceIDs)
        let pendingIDs = Set(upsertedPieces.map(\.id))
        upsertedPieces.removeAll { removed.contains($0.id) }
        // Pieces that only ever existed inside this change set need no removal in the store.
        removedPieceIDs += other.removedPieceIDs.filter { !pendingIDs.contains($0) }
        upsertedPieces += other.upsertedPieces
        dataVersions.merge(other.dataVersions) { _, new in new }
    }
}
