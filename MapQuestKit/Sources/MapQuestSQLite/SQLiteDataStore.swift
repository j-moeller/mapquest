import Foundation
import MapQuestCore

/// The local `MapQuestDataStore`: one SQLite database file holding both the
/// location samples and the discovered-area pieces of one data source.
///
/// All database work runs on a private serial queue, so the store can be used
/// from any task without blocking Swift's cooperative thread pool.
public final class SQLiteDataStore: MapQuestDataStore, @unchecked Sendable {
    public let descriptor: DataSourceDescriptor
    /// Database file location, or `nil` for an in-memory database.
    public let fileURL: URL?

    private let connection: SQLiteConnection
    private let queue: DispatchQueue

    /// The schema version this code writes. Bump and add a migration step for every change.
    public static let schemaVersion = 2

    /// Opens or creates the database at `url`.
    public convenience init(fileURL url: URL, descriptor: DataSourceDescriptor? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try self.init(
            path: url.path,
            fileURL: url,
            descriptor: descriptor ?? DataSourceDescriptor(
                id: url.deletingPathExtension().lastPathComponent,
                displayName: url.deletingPathExtension().lastPathComponent,
                kind: .localDatabase(path: url.path)
            )
        )
    }

    /// Creates a private in-memory database (tests, previews).
    public static func inMemory(descriptor: DataSourceDescriptor? = nil) throws -> SQLiteDataStore {
        try SQLiteDataStore(
            path: ":memory:",
            fileURL: nil,
            descriptor: descriptor ?? DataSourceDescriptor(id: "sqlite-memory", displayName: "In-memory SQLite", kind: .inMemory)
        )
    }

    private init(path: String, fileURL: URL?, descriptor: DataSourceDescriptor) throws {
        self.descriptor = descriptor
        self.fileURL = fileURL
        self.connection = try SQLiteConnection(path: path)
        self.queue = DispatchQueue(label: "MapQuest.SQLiteDataStore.\(descriptor.id)")
        try Self.migrate(connection, isFile: fileURL != nil)
    }

    // MARK: Schema

    private static func migrate(_ db: SQLiteConnection, isFile: Bool) throws {
        if isFile {
            try db.execute("PRAGMA journal_mode = WAL")
            try db.execute("PRAGMA synchronous = NORMAL")
        }
        let version = try db.userVersion
        guard version < schemaVersion else { return }
        try db.transaction {
            if version < 1 {
                try db.execute("""
                CREATE TABLE location_samples (
                    id                  TEXT PRIMARY KEY NOT NULL,
                    latitude            REAL NOT NULL,
                    longitude           REAL NOT NULL,
                    altitude            REAL NOT NULL,
                    horizontal_accuracy REAL NOT NULL,
                    vertical_accuracy   REAL NOT NULL,
                    timestamp           REAL NOT NULL,
                    tile_x              INTEGER NOT NULL,
                    tile_y              INTEGER NOT NULL
                );
                CREATE INDEX location_samples_tile ON location_samples (tile_x, tile_y);
                CREATE INDEX location_samples_time ON location_samples (timestamp);

                CREATE TABLE discovered_pieces (
                    id               TEXT PRIMARY KEY NOT NULL,
                    layer            TEXT NOT NULL,
                    region_id        TEXT NOT NULL,
                    tile_zoom        INTEGER NOT NULL,
                    tile_x           INTEGER NOT NULL,
                    tile_y           INTEGER NOT NULL,
                    geometry         BLOB NOT NULL,
                    area_m2          REAL NOT NULL,
                    first_discovered REAL NOT NULL,
                    last_updated     REAL NOT NULL
                );
                CREATE INDEX discovered_pieces_tile ON discovered_pieces (layer, tile_x, tile_y);
                CREATE INDEX discovered_pieces_region ON discovered_pieces (layer, region_id);

                CREATE TABLE metadata (
                    key   TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """)
            }
            if version < 2 {
                // Data watermarks (docs/05-cache-invalidation.md).
                try db.execute("""
                CREATE TABLE layer_data_versions (
                    layer   TEXT NOT NULL,
                    zoom    INTEGER NOT NULL,
                    x       INTEGER NOT NULL,
                    y       INTEGER NOT NULL,
                    version TEXT NOT NULL,
                    PRIMARY KEY (layer, zoom, x, y)
                ) WITHOUT ROWID;
                """)
            }
            try db.setUserVersion(schemaVersion)
        }
    }

    // MARK: Serial execution

    private func perform<T: Sendable>(_ work: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        let connection = self.connection
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work(connection) })
            }
        }
    }

    // MARK: Metadata

    /// Free-form key/value metadata (e.g. the display name of the data owner).
    public func metadata(_ key: String) async throws -> String? {
        try await perform { db in
            let statement = try db.prepare("SELECT value FROM metadata WHERE key = ?")
            try statement.bind(key, at: 1)
            return try statement.step() ? statement.string(at: 0) : nil
        }
    }

    public func setMetadata(_ key: String, value: String?) async throws {
        try await perform { db in
            if let value {
                try db.prepare("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)").run([.text(key), .text(value)])
            } else {
                try db.prepare("DELETE FROM metadata WHERE key = ?").run([.text(key)])
            }
        }
    }

    // MARK: LocationStore

    public func addSamples(_ samples: [LocationSample]) async throws {
        guard !samples.isEmpty else { return }
        try await perform { db in
            try db.transaction {
                let insert = try db.prepare("""
                INSERT OR REPLACE INTO location_samples
                    (id, latitude, longitude, altitude, horizontal_accuracy, vertical_accuracy, timestamp, tile_x, tile_y)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
                for sample in samples {
                    let tile = sample.tile
                    try insert.run([
                        .text(sample.id.uuidString), .real(sample.latitude), .real(sample.longitude),
                        .real(sample.altitude), .real(sample.horizontalAccuracy), .real(sample.verticalAccuracy),
                        .real(sample.timestamp.timeIntervalSince1970), .integer(Int64(tile.x)), .integer(Int64(tile.y)),
                    ])
                }
            }
        }
    }

    public func samples(matching query: LocationQuery) async throws -> [LocationSample] {
        try await perform { db in
            var conditions: [String] = []
            var values: [SQLiteValue] = []
            if let tiles = query.tiles {
                precondition(tiles.zoom == DiscoveryGrid.zoom, "sample tile queries must use the storage grid zoom")
                conditions.append("tile_x BETWEEN ? AND ? AND tile_y BETWEEN ? AND ?")
                values += [.integer(Int64(tiles.minX)), .integer(Int64(tiles.maxX)), .integer(Int64(tiles.minY)), .integer(Int64(tiles.maxY))]
            }
            if let box = query.boundingBox {
                conditions.append("latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?")
                values += [.real(box.minLatitude), .real(box.maxLatitude), .real(box.minLongitude), .real(box.maxLongitude)]
            }
            if let from = query.from {
                conditions.append("timestamp >= ?")
                values.append(.real(from.timeIntervalSince1970))
            }
            if let to = query.to {
                conditions.append("timestamp < ?")
                values.append(.real(to.timeIntervalSince1970))
            }
            var sql = """
            SELECT id, latitude, longitude, altitude, horizontal_accuracy, vertical_accuracy, timestamp
            FROM location_samples
            """
            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            switch query.order {
            case .chronological: sql += " ORDER BY timestamp ASC, id ASC"
            case .reverseChronological: sql += " ORDER BY timestamp DESC, id DESC"
            }
            if let limit = query.limit {
                sql += " LIMIT \(max(limit, 0))"
            }
            let statement = try db.prepare(sql)
            try statement.bind(values)
            var result: [LocationSample] = []
            while try statement.step() {
                guard let id = UUID(uuidString: statement.string(at: 0)) else { continue }
                result.append(LocationSample(
                    id: id,
                    latitude: statement.double(at: 1),
                    longitude: statement.double(at: 2),
                    altitude: statement.double(at: 3),
                    horizontalAccuracy: statement.double(at: 4),
                    verticalAccuracy: statement.double(at: 5),
                    timestamp: Date(timeIntervalSince1970: statement.double(at: 6))
                ))
            }
            statement.reset()
            return result
        }
    }

    public func sampleCount() async throws -> Int {
        try await perform { db in
            let statement = try db.prepare("SELECT COUNT(*) FROM location_samples")
            _ = try statement.step()
            let count = statement.int(at: 0)
            statement.reset()
            return count
        }
    }

    public func removeAllSamples() async throws {
        try await perform { db in
            try db.execute("DELETE FROM location_samples")
        }
    }

    // MARK: DiscoveredAreaStore

    public func pieces(layer: DiscoveryLayerID, tiles: TileRange?) async throws -> [DiscoveredPiece] {
        try await perform { db in
            var sql = """
            SELECT id, region_id, tile_zoom, tile_x, tile_y, geometry, area_m2, first_discovered, last_updated
            FROM discovered_pieces WHERE layer = ?
            """
            var values: [SQLiteValue] = [.text(layer.rawValue)]
            if let tiles {
                sql += " AND tile_x BETWEEN ? AND ? AND tile_y BETWEEN ? AND ? AND tile_zoom = ?"
                values += [
                    .integer(Int64(tiles.minX)), .integer(Int64(tiles.maxX)),
                    .integer(Int64(tiles.minY)), .integer(Int64(tiles.maxY)), .integer(Int64(tiles.zoom)),
                ]
            }
            sql += " ORDER BY tile_y, tile_x, id"
            let statement = try db.prepare(sql)
            try statement.bind(values)
            var result: [DiscoveredPiece] = []
            while try statement.step() {
                guard
                    let id = UUID(uuidString: statement.string(at: 0)),
                    let region = UUID(uuidString: statement.string(at: 1))
                else { continue }
                let tile = TileKey(zoom: statement.int(at: 2), x: statement.int(at: 3), y: statement.int(at: 4))
                let polygon = try PolygonCodec.decodePolygon(statement.data(at: 5), origin: tile.origin)
                result.append(DiscoveredPiece(
                    id: id, layer: layer, regionID: region, tile: tile, polygon: polygon,
                    areaSquareMeters: statement.double(at: 6),
                    firstDiscovered: Date(timeIntervalSince1970: statement.double(at: 7)),
                    lastUpdated: Date(timeIntervalSince1970: statement.double(at: 8))
                ))
            }
            statement.reset()
            return result
        }
    }

    public func apply(_ changes: DiscoveredAreaChangeSet) async throws {
        guard !changes.isEmpty else { return }
        try await perform { db in
            try db.transaction {
                let relabel = try db.prepare("UPDATE discovered_pieces SET region_id = ? WHERE layer = ? AND region_id = ?")
                for merge in changes.regionMerges {
                    for source in merge.sources where source != merge.target {
                        try relabel.run([.text(merge.target.uuidString), .text(changes.layer.rawValue), .text(source.uuidString)])
                    }
                }
                let delete = try db.prepare("DELETE FROM discovered_pieces WHERE id = ? AND layer = ?")
                for id in changes.removedPieceIDs {
                    try delete.run([.text(id.uuidString), .text(changes.layer.rawValue)])
                }
                let insert = try db.prepare("""
                INSERT OR REPLACE INTO discovered_pieces
                    (id, layer, region_id, tile_zoom, tile_x, tile_y, geometry, area_m2, first_discovered, last_updated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
                for piece in changes.upsertedPieces {
                    precondition(piece.layer == changes.layer, "piece layer does not match change set layer")
                    try insert.run([
                        .text(piece.id.uuidString), .text(piece.layer.rawValue), .text(piece.regionID.uuidString),
                        .integer(Int64(piece.tile.zoom)), .integer(Int64(piece.tile.x)), .integer(Int64(piece.tile.y)),
                        .blob(PolygonCodec.encode(piece.polygon, origin: piece.tile.origin)),
                        .real(piece.areaSquareMeters),
                        .real(piece.firstDiscovered.timeIntervalSince1970), .real(piece.lastUpdated.timeIntervalSince1970),
                    ])
                }
                let watermark = try db.prepare("INSERT OR REPLACE INTO layer_data_versions (layer, zoom, x, y, version) VALUES (?, ?, ?, ?, ?)")
                for (tile, version) in changes.dataVersions {
                    try watermark.run([
                        .text(changes.layer.rawValue), .integer(Int64(tile.zoom)), .integer(Int64(tile.x)), .integer(Int64(tile.y)),
                        .text(version),
                    ])
                }
            }
        }
    }

    public func removeAllPieces(layer: DiscoveryLayerID) async throws {
        try await perform { db in
            try db.transaction {
                try db.prepare("DELETE FROM discovered_pieces WHERE layer = ?").run([.text(layer.rawValue)])
                try db.prepare("DELETE FROM layer_data_versions WHERE layer = ?").run([.text(layer.rawValue)])
            }
        }
    }

    public func dataVersions(layer: DiscoveryLayerID) async throws -> DataVersions {
        try await perform { db in
            let statement = try db.prepare("SELECT zoom, x, y, version FROM layer_data_versions WHERE layer = ?")
            try statement.bind([.text(layer.rawValue)])
            var result: DataVersions = [:]
            while try statement.step() {
                result[TileKey(zoom: statement.int(at: 0), x: statement.int(at: 1), y: statement.int(at: 2))] = statement.string(at: 3)
            }
            statement.reset()
            return result
        }
    }

    public func layers() async throws -> [DiscoveryLayerID] {
        try await perform { db in
            let statement = try db.prepare("SELECT DISTINCT layer FROM discovered_pieces ORDER BY layer")
            var result: [DiscoveryLayerID] = []
            while try statement.step() {
                result.append(DiscoveryLayerID(statement.string(at: 0)))
            }
            statement.reset()
            return result
        }
    }
}
