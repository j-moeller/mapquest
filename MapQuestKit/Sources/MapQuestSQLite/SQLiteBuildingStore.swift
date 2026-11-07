import Foundation
import MapQuestCore

/// A SQLite database of LoD1 buildings: the bundled Berlin dataset and the
/// cache for buildings downloaded on demand. Building data is map data, not
/// user data, so one database is shared by all data sources.
public final class SQLiteBuildingStore: BuildingCache, @unchecked Sendable {
    public let fileURL: URL?
    private let connection: SQLiteConnection
    private let queue = DispatchQueue(label: "MapQuest.SQLiteBuildingStore")

    public static let schemaVersion = 1
    /// Buildings are indexed by the storage-grid tile containing their bounds centre;
    /// queries look this many tiles further out to catch large buildings.
    static let tileReach = 2

    public init(fileURL url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileURL = url
        connection = try SQLiteConnection(path: url.path)
        try Self.migrate(connection, isFile: true)
    }

    public static func inMemory() throws -> SQLiteBuildingStore {
        try SQLiteBuildingStore(connection: SQLiteConnection(path: ":memory:"))
    }

    private init(connection: SQLiteConnection) throws {
        fileURL = nil
        self.connection = connection
        try Self.migrate(connection, isFile: false)
    }

    private static func migrate(_ db: SQLiteConnection, isFile: Bool) throws {
        if isFile {
            try db.execute("PRAGMA journal_mode = WAL")
        }
        guard try db.userVersion < schemaVersion else { return }
        try db.transaction {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS buildings (
                id            INTEGER PRIMARY KEY NOT NULL,
                tile_x        INTEGER NOT NULL,
                tile_y        INTEGER NOT NULL,
                min_x         INTEGER NOT NULL,
                min_y         INTEGER NOT NULL,
                max_x         INTEGER NOT NULL,
                max_y         INTEGER NOT NULL,
                height        REAL NOT NULL,
                min_height    REAL NOT NULL,
                height_source INTEGER NOT NULL,
                name          TEXT,
                geometry      BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS buildings_tile ON buildings (tile_x, tile_y);
            CREATE TABLE IF NOT EXISTS downloaded_tiles (
                zoom          INTEGER NOT NULL,
                x             INTEGER NOT NULL,
                y             INTEGER NOT NULL,
                downloaded_at REAL NOT NULL,
                PRIMARY KEY (zoom, x, y)
            );
            CREATE TABLE IF NOT EXISTS metadata (
                key   TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """)
            try db.setUserVersion(schemaVersion)
        }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        let connection = self.connection
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work(connection) }) }
        }
    }

    // MARK: BuildingCache

    public func buildings(in rect: WorldRect) async throws -> [Building] {
        try await perform { db in
            let tiles = TileRange(covering: rect, zoom: DiscoveryGrid.zoom).expanded(by: Self.tileReach)
            let statement = try db.prepare("""
            SELECT id, tile_x, tile_y, height, min_height, height_source, name, geometry FROM buildings
            WHERE tile_x BETWEEN ? AND ? AND tile_y BETWEEN ? AND ?
              AND max_x >= ? AND min_x <= ? AND max_y >= ? AND min_y <= ?
            ORDER BY id
            """)
            try statement.bind([
                .integer(Int64(tiles.minX)), .integer(Int64(tiles.maxX)), .integer(Int64(tiles.minY)), .integer(Int64(tiles.maxY)),
                .integer(rect.minX), .integer(rect.maxX), .integer(rect.minY), .integer(rect.maxY),
            ])
            var result: [Building] = []
            while try statement.step() {
                let tile = TileKey(zoom: DiscoveryGrid.zoom, x: statement.int(at: 1), y: statement.int(at: 2))
                let footprint = try PolygonCodec.decodePolygon(statement.data(at: 7), origin: tile.origin)
                result.append(Building(
                    id: statement.int64(at: 0),
                    footprint: footprint,
                    height: statement.double(at: 3),
                    minHeight: statement.double(at: 4),
                    heightSource: Building.HeightSource(rawValue: statement.int(at: 5)) ?? .estimated,
                    name: statement.isNull(at: 6) ? nil : statement.string(at: 6)
                ))
            }
            statement.reset()
            return result
        }
    }

    public func isDownloaded(_ tile: TileKey) async throws -> Bool {
        try await perform { db in
            let statement = try db.prepare("SELECT 1 FROM downloaded_tiles WHERE zoom = ? AND x = ? AND y = ?")
            try statement.bind([.integer(Int64(tile.zoom)), .integer(Int64(tile.x)), .integer(Int64(tile.y))])
            let found = try statement.step()
            statement.reset()
            return found
        }
    }

    public func store(_ buildings: [Building], downloadedTiles tiles: [TileKey]) async throws {
        try await perform { db in
            try db.transaction {
                let insert = try db.prepare("""
                INSERT OR REPLACE INTO buildings
                    (id, tile_x, tile_y, min_x, min_y, max_x, max_y, height, min_height, height_source, name, geometry)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
                for building in buildings {
                    let bounds = building.bounds
                    let tile = TileKey(containing: bounds.center, zoom: DiscoveryGrid.zoom)
                    try insert.run([
                        .integer(building.id), .integer(Int64(tile.x)), .integer(Int64(tile.y)),
                        .integer(bounds.minX), .integer(bounds.minY), .integer(bounds.maxX), .integer(bounds.maxY),
                        .real(building.height), .real(building.minHeight), .integer(Int64(building.heightSource.rawValue)),
                        building.name.map { SQLiteValue.text($0) } ?? SQLiteValue.null,
                        .blob(PolygonCodec.encode(building.footprint, origin: tile.origin)),
                    ])
                }
                let mark = try db.prepare("INSERT OR REPLACE INTO downloaded_tiles (zoom, x, y, downloaded_at) VALUES (?, ?, ?, ?)")
                let now = Date().timeIntervalSince1970
                for tile in tiles {
                    try mark.run([.integer(Int64(tile.zoom)), .integer(Int64(tile.x)), .integer(Int64(tile.y)), .real(now)])
                }
            }
        }
    }

    // MARK: Maintenance

    public func buildingCount() async throws -> Int {
        try await perform { db in
            let statement = try db.prepare("SELECT COUNT(*) FROM buildings")
            _ = try statement.step()
            let count = statement.int(at: 0)
            statement.reset()
            return count
        }
    }

    public func downloadedTiles() async throws -> [TileKey] {
        try await perform { db in
            let statement = try db.prepare("SELECT zoom, x, y FROM downloaded_tiles ORDER BY zoom, y, x")
            var tiles: [TileKey] = []
            while try statement.step() {
                tiles.append(TileKey(zoom: statement.int(at: 0), x: statement.int(at: 1), y: statement.int(at: 2)))
            }
            statement.reset()
            return tiles
        }
    }

    /// Rewrites the database file compactly (after a large import).
    public func compact() async throws {
        try await perform { db in
            if self.fileURL != nil { try db.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
            try db.execute("VACUUM")
        }
    }

    public func setMetadata(_ key: String, value: String) async throws {
        try await perform { db in
            try db.prepare("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)").run([.text(key), .text(value)])
        }
    }

    public func metadata(_ key: String) async throws -> String? {
        try await perform { db in
            let statement = try db.prepare("SELECT value FROM metadata WHERE key = ?")
            try statement.bind(key, at: 1)
            let value = try statement.step() ? statement.string(at: 0) : nil
            statement.reset()
            return value
        }
    }
}
