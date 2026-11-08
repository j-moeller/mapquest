import Foundation

/// A query for location samples. All filters are optional and combined with AND.
public struct LocationQuery: Hashable, Sendable {
    public enum Order: Hashable, Sendable {
        case chronological
        case reverseChronological
    }

    /// Storage-grid tiles (zoom `DiscoveryGrid.zoom`) to search – the indexed spatial filter.
    public var tiles: TileRange?
    /// Exact geographic filter, applied on top of `tiles`.
    public var boundingBox: GeoBoundingBox?
    /// Inclusive lower time bound.
    public var from: Date?
    /// Exclusive upper time bound.
    public var to: Date?
    public var order: Order
    public var limit: Int?

    public init(
        tiles: TileRange? = nil,
        boundingBox: GeoBoundingBox? = nil,
        from: Date? = nil,
        to: Date? = nil,
        order: Order = .chronological,
        limit: Int? = nil
    ) {
        self.tiles = tiles
        self.boundingBox = boundingBox
        self.from = from
        self.to = to
        self.order = order
        self.limit = limit
    }

    /// Every sample, oldest first.
    public static let all = LocationQuery()

    /// Samples inside a bounding box (uses the tile index plus an exact filter).
    public static func within(_ box: GeoBoundingBox) -> LocationQuery {
        LocationQuery(tiles: TileRange(covering: box, zoom: DiscoveryGrid.zoom), boundingBox: box)
    }

    /// Whether `sample` satisfies the filters (ignores order and limit).
    public func matches(_ sample: LocationSample) -> Bool {
        if let tiles, !tiles.contains(sample.tile) { return false }
        if let boundingBox, !boundingBox.contains(sample.coordinate) { return false }
        if let from, sample.timestamp < from { return false }
        if let to, sample.timestamp >= to { return false }
        return true
    }
}

/// General-purpose datastore for position data – the location half of the model.
///
/// Implementations must be safe to call from any task. The app never depends on
/// a concrete implementation, so a local database, a remote service, or another
/// user's data can be swapped in without touching the rest of the app.
public protocol LocationStore: AnyObject, Sendable {
    /// Inserts samples. Samples whose `id` already exists are replaced.
    func addSamples(_ samples: [LocationSample]) async throws
    func samples(matching query: LocationQuery) async throws -> [LocationSample]
    func sampleCount() async throws -> Int
    func removeAllSamples() async throws
}

/// Storage of discovered-area pieces, organised in layers – the area half of the model.
public protocol DiscoveredAreaStore: AnyObject, Sendable {
    /// Pieces of a layer, optionally restricted to a tile range (at `DiscoveryGrid.zoom`).
    func pieces(layer: DiscoveryLayerID, tiles: TileRange?) async throws -> [DiscoveredPiece]
    /// Applies a change set atomically.
    func apply(_ changes: DiscoveredAreaChangeSet) async throws
    /// Deletes every piece and data watermark of a layer (e.g. before a rebuild).
    func removeAllPieces(layer: DiscoveryLayerID) async throws
    /// The layers that currently hold pieces.
    func layers() async throws -> [DiscoveryLayerID]
    /// The data watermarks of a layer: for every data tile its results depend on,
    /// the version of the map data they were computed from.
    func dataVersions(layer: DiscoveryLayerID) async throws -> DataVersions
}

public extension DiscoveredAreaStore {
    /// Connected regions of a layer, aggregated from its pieces.
    func regions(layer: DiscoveryLayerID) async throws -> [DiscoveredRegion] {
        DiscoveredRegion.aggregate(try await pieces(layer: layer, tiles: nil))
    }

    /// Replaces a whole layer (used when rebuilding the cache).
    func replaceLayer(_ layer: DiscoveryLayerID, with pieces: [DiscoveredPiece], dataVersions: DataVersions = [:]) async throws {
        try await removeAllPieces(layer: layer)
        try await apply(DiscoveredAreaChangeSet(layer: layer, upsertedPieces: pieces, dataVersions: dataVersions))
    }
}

/// Location data and discovered area always belong together, so a data source
/// provides both. Switching the app's data source (local ↔ remote, user 1 ↔
/// user 2) means swapping one `MapQuestDataStore`.
public protocol MapQuestDataStore: LocationStore, DiscoveredAreaStore {
    var descriptor: DataSourceDescriptor { get }
}

/// Describes where a data store lives; persisted by the app to remember the
/// selected data source.
public struct DataSourceDescriptor: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: Hashable, Codable, Sendable {
        /// A SQLite database file (path relative to the app's data directory, or absolute).
        case localDatabase(path: String)
        /// Volatile storage (tests, previews).
        case inMemory
        /// A remote service (not implemented in the prototype).
        case remote(baseURL: URL, userID: String)
    }

    public var id: String
    public var displayName: String
    public var kind: Kind

    public init(id: String, displayName: String, kind: Kind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}
