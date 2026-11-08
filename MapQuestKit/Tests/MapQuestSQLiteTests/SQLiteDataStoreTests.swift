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

    func testTrackStoreContract() async throws {
        try await DataStoreContract.verifyTrackStore(SQLiteDataStore.inMemory())
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

    func testVersion1DatabaseIsMigrated() async throws {
        // A database written by the first version: pieces, but no data watermarks.
        let url = temporaryDirectory.appendingPathComponent("v1.sqlite")
        do {
            let store = try SQLiteDataStore(fileURL: url)
            let piece = DataStoreContract.makePiece(layer: "viewshed-v2", region: UUID(), tileX: 35_200, firstDiscovered: Date())
            try await store.apply(DiscoveredAreaChangeSet(layer: "viewshed-v2", upsertedPieces: [piece]))
        }
        do {
            let raw = try SQLiteConnection(path: url.path)
            try raw.execute("DROP TABLE layer_data_versions")
            try raw.execute("DROP TABLE track_segments")
            try raw.setUserVersion(1)
        }
        let store = try SQLiteDataStore(fileURL: url)
        let tile = TileKey(zoom: DataGrid.zoom, x: 8_800, y: 5_373)
        try await store.apply(DiscoveredAreaChangeSet(layer: "viewshed-v3", dataVersions: [tile: "bundle:1"]))
        let versions = try await store.dataVersions(layer: "viewshed-v3")
        XCTAssertEqual(versions, [tile: "bundle:1"])
        let pieces = try await store.pieces(layer: "viewshed-v2", tiles: nil)
        XCTAssertEqual(pieces.count, 1, "existing data is kept")
        try await store.putTrackSegments([TrackSegment(points: DataStoreContract.makeTrack(count: 10))])
        let summary = try await store.trackSummary()
        XCTAssertEqual(summary.pointCount, 10)
        XCTAssertEqual(try SQLiteConnection(path: url.path).userVersion, SQLiteDataStore.schemaVersion)
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

final class SQLiteDiscoveryIntegrationTests: XCTestCase {
    func testRecorderOnSQLiteSurvivesReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mq-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = CircleDiscoveryModel(radius: 50)
        let origin = GeoCoordinate(latitude: 52.52, longitude: 13.405)
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let walk = (0..<200).map { i in
            LocationSample(
                latitude: origin.latitude, longitude: origin.longitude + Double(i) * 2 / 67_800,
                altitude: 40, horizontalAccuracy: 5, verticalAccuracy: 3, timestamp: start.addingTimeInterval(Double(i))
            )
        }
        var storedCount = 0
        var area = 0.0
        do {
            let store = try SQLiteDataStore(fileURL: url)
            let engine = DiscoveryEngine(model: model, store: store)
            let recorder = LocationRecorder(store: store, engines: [engine])
            for sample in walk { _ = try await recorder.record(sample) }
            try await recorder.finishSampling()
            storedCount = try await store.sampleCount()
            area = await engine.snapshot().totalAreaSquareMeters
        }
        XCTAssertGreaterThan(storedCount, 20)
        XCTAssertLessThan(storedCount, walk.count / 3, "only fixes revealing new area are stored")

        let reopened = try SQLiteDataStore(fileURL: url)
        let engine = DiscoveryEngine(model: model, store: reopened)
        try await engine.loadAll()
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.totalAreaSquareMeters, area, accuracy: 1e-6)
        XCTAssertEqual(snapshot.regions.count, 1)
        // ~400 m walk: corridor of 400 m × 100 m plus the end caps.
        XCTAssertEqual(area, 400 * 100 + .pi * 2_500, accuracy: 1_000)
        let known = try await engine.isDiscovered(walk[100].coordinate)
        XCTAssertTrue(known)
    }
}

final class SQLiteBuildingStoreTests: XCTestCase {
    func building(_ id: Int64, lat: Double, lon: Double, size: Double = 0.0003, height: Double = 20, name: String? = nil) -> Building {
        let ring = [
            GeoCoordinate(latitude: lat, longitude: lon), GeoCoordinate(latitude: lat, longitude: lon + size),
            GeoCoordinate(latitude: lat + size, longitude: lon + size), GeoCoordinate(latitude: lat + size, longitude: lon),
        ].map(WebMercator.project)
        return Building(id: id, footprint: WorldPolygon(exterior: ring), height: height, minHeight: 0, heightSource: .levels, name: name)
    }

    func testStoresAndQueriesBuildings() async throws {
        let store = try SQLiteBuildingStore.inMemory()
        let near = building(1, lat: 52.5200, lon: 13.4100, name: "Near")
        let far = building(2, lat: 52.5300, lon: 13.4300)
        // A very large building (≈ 1 km) whose centre lies far from the query.
        let large = building(3, lat: 52.5150, lon: 13.4000, size: 0.012)
        let tile = TileKey(containing: GeoCoordinate(latitude: 52.52, longitude: 13.41), zoom: 14)
        try await store.store([near, far, large], downloadedTiles: [tile])

        let rect = WebMercator.worldRect(for: GeoBoundingBox(center: GeoCoordinate(latitude: 52.5201, longitude: 13.4101), radius: 50))
        let found = try await store.buildings(in: rect)
        XCTAssertEqual(found.map(\.id), [1, 3])
        XCTAssertEqual(found.first, near, "all fields round-trip")
        let downloaded = try await store.isDownloaded(tile)
        XCTAssertTrue(downloaded)
        let otherTileDownloaded = try await store.isDownloaded(TileKey(zoom: 14, x: tile.x + 1, y: tile.y))
        XCTAssertFalse(otherTileDownloaded)
        let count = try await store.buildingCount()
        XCTAssertEqual(count, 3)
    }

    func testViewshedOnCachedBuildings() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("buildings-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteBuildingStore(fileURL: url)
        let source = CachingBuildingSource(cache: store, download: { [self] _ in
            [building(10, lat: 52.52020, lon: 13.40980, height: 25)]
        })
        let model = ViewshedDiscoveryModel(buildings: source)
        let sample = LocationSample(latitude: 52.52000, longitude: 13.41000, altitude: 36, verticalAccuracy: 4, timestamp: Date())
        let result = try await model.viewshed(for: sample)
        XCTAssertEqual(result.seenBuildingIDs, [10])
        let tiles = try await store.downloadedTiles()
        XCTAssertFalse(tiles.isEmpty)
    }
}

final class BuildingImporterTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/berlin/fixtures")

    func testImportsExtractedBuildingsAndMarksCompleteTiles() async throws {
        let store = try SQLiteBuildingStore.inMemory()
        var data = try Data(contentsOf: Self.fixtures.appendingPathComponent("sample.jsonl"))
        data.append(Data("this is not json\n".utf8))
        let report = try await BuildingImporter.importOverpassLines(data, into: store, batchSize: 2)
        XCTAssertEqual(report.buildings, 3)
        XCTAssertEqual(report.skippedLines, 1)
        XCTAssertEqual(report.heightSources[.tagged], 2)
        XCTAssertEqual(report.heightSources[.levels], 1)

        let rect = WebMercator.worldRect(for: GeoBoundingBox(center: GeoCoordinate(latitude: 52.519, longitude: 13.411), radius: 400))
        let buildings = try await store.buildings(in: rect)
        XCTAssertEqual(buildings.count, 3)
        XCTAssertEqual(buildings.first { $0.name == "Berliner Fernsehturm" }?.height, 368)
        XCTAssertEqual(buildings.first { $0.id < 0 }?.footprint.holes.count, 1)

        // A 4 km square: only zoom-14 tiles entirely inside are complete.
        let square = WorldPolygon(exterior: WebMercator.worldRect(
            for: GeoBoundingBox(center: GeoCoordinate(latitude: 52.52, longitude: 13.41), radius: 2_000)
        ).corners)
        let marked = try await BuildingImporter.markTilesComplete(inside: [square], in: store)
        XCTAssertGreaterThanOrEqual(marked, 1)
        XCTAssertLessThanOrEqual(marked, 4)
        let tiles = try await store.downloadedTiles()
        XCTAssertEqual(tiles.count, marked)
        XCTAssertTrue(tiles.allSatisfy { $0.zoom == 14 })
    }
}
