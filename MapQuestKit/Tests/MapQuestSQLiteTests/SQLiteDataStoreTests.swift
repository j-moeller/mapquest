import XCTest
import MapQuestCore
import MapQuestTestSupport
@testable import MapQuestSQLite

final class SQLiteDataStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapQuestSQLiteTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testLocationStoreContract() async throws {
        try await DataStoreContract.verifyLocationStore(SQLiteDataStore.inMemory())
    }

    func testDiscoveredAreaStoreContract() async throws {
        try await DataStoreContract.verifyDiscoveredAreaStore(SQLiteDataStore.inMemory())
    }

    func testFileDatabasePersistsAcrossReopen() async throws {
        let url = temporaryDirectory.appendingPathComponent("user-1.sqlite")
        let samples = DataStoreContract.makeSamples()
        let piece = DataStoreContract.makePiece(layer: "circle-50m", region: UUID(), tileX: 35_200, firstDiscovered: Date())
        do {
            let store = try SQLiteDataStore(fileURL: url)
            XCTAssertEqual(store.descriptor.id, "user-1")
            try await store.addSamples(samples)
            try await store.apply(DiscoveredAreaChangeSet(layer: "circle-50m", upsertedPieces: [piece]))
            try await store.setMetadata("owner", value: "Alice")
        }
        let reopened = try SQLiteDataStore(fileURL: url)
        let count = try await reopened.sampleCount()
        XCTAssertEqual(count, samples.count)
        let pieces = try await reopened.pieces(layer: "circle-50m", tiles: nil)
        XCTAssertEqual(pieces.map(\.id), [piece.id])
        XCTAssertEqual(pieces.first?.polygon, piece.polygon)
        let owner = try await reopened.metadata("owner")
        XCTAssertEqual(owner, "Alice")
    }

    func testSchemaVersionIsRecorded() throws {
        let url = temporaryDirectory.appendingPathComponent("versioned.sqlite")
        _ = try SQLiteDataStore(fileURL: url)
        let raw = try SQLiteConnection(path: url.path)
        XCTAssertEqual(try raw.userVersion, SQLiteDataStore.schemaVersion)
        // Opening an up-to-date database again must not re-run migrations.
        XCTAssertNoThrow(try SQLiteDataStore(fileURL: url))
    }

    func testFailedTransactionRollsBack() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE t (v INTEGER NOT NULL)")
        XCTAssertThrowsError(try db.transaction {
            try db.prepare("INSERT INTO t (v) VALUES (?)").run([.integer(1)])
            try db.prepare("INSERT INTO t (v) VALUES (?)").run([.null])
        })
        let statement = try db.prepare("SELECT COUNT(*) FROM t")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.int(at: 0), 0)
    }

    func testTileIndexIsUsedForSpatialQueries() throws {
        let db = try SQLiteConnection(path: ":memory:")
        _ = try SQLiteDataStore.inMemory()
        try db.execute("""
        CREATE TABLE location_samples (id TEXT PRIMARY KEY, latitude REAL, longitude REAL, timestamp REAL, tile_x INTEGER, tile_y INTEGER);
        CREATE INDEX location_samples_tile ON location_samples (tile_x, tile_y);
        """)
        let plan = try db.prepare("EXPLAIN QUERY PLAN SELECT id FROM location_samples WHERE tile_x BETWEEN 1 AND 2 AND tile_y BETWEEN 1 AND 2")
        var details: [String] = []
        while try plan.step() { details.append(plan.string(at: 3)) }
        XCTAssertTrue(details.contains { $0.contains("location_samples_tile") }, "plan: \(details)")
    }
}
