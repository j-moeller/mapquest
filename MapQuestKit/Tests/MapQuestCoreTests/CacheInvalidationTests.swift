import XCTest
@testable import MapQuestCore

/// Building data per data tile, with versions, that a test can change – as when
/// buildings are downloaded or a newer dataset is installed.
final class VersionedBuildingSource: BuildingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Building] = []
    private var versions: DataVersions = [:]
    private var calls = 0
    /// Simulated computation/download time per coverage request.
    var delayNanoseconds: UInt64 = 0

    var coverageCalls: Int { lock.withLock { calls } }

    /// Makes data available for `tiles` (replacing earlier data of these tiles).
    func publish(_ buildings: [Building], tiles: [TileKey], version: String) {
        lock.withLock {
            let replaced = Set(tiles)
            all.removeAll { replaced.contains(Self.dataTile(of: $0)) }
            all += buildings.filter { replaced.contains(Self.dataTile(of: $0)) }
            for tile in tiles { versions[tile] = version }
        }
    }

    static func dataTile(of building: Building) -> TileKey {
        TileKey(containing: building.bounds.center, zoom: DataGrid.zoom)
    }

    func buildings(in rect: WorldRect) -> [Building] { available(in: rect) }

    func coverage(in rect: WorldRect) async -> BuildingCoverage {
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        lock.withLock { calls += 1 }
        let tiles = Array(TileRange(covering: rect, zoom: DataGrid.zoom))
        return BuildingCoverage(buildings: available(in: rect), versions: current(tiles))
    }

    func dataVersions(of tiles: [TileKey], fetchingMissing: Bool) -> DataVersions { current(tiles) }

    private func available(in rect: WorldRect) -> [Building] {
        lock.withLock {
            all.filter { $0.bounds.intersects(rect) && versions[Self.dataTile(of: $0)] != nil }
        }
    }

    private func current(_ tiles: [TileKey]) -> DataVersions {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: tiles.map { ($0, versions[$0] ?? DataGrid.noData) })
        }
    }
}

final class CacheInvalidationTests: XCTestCase {
    // MARK: Fixtures

    /// Metres east/north of `Walk.origin` of a world point.
    func offset(of point: WorldPoint) -> (east: Double, north: Double) {
        let coordinate = WebMercator.unproject(point)
        let east = (coordinate.longitude - Walk.origin.longitude) * 111_320 * cos(Walk.origin.latitude * .pi / 180)
        return (east, (coordinate.latitude - Walk.origin.latitude) * 111_320)
    }

    func point(east: Double, north: Double) -> WorldPoint {
        WebMercator.project(Walk.coordinate(east: east, north: north))
    }

    /// Blocks of 80 × 80 m with 20 m wide streets on the multiples of 100 m.
    func cityGrid(around center: (east: Double, north: Double) = (0, 0), blocks: Int = 8, height: Double = 20) -> [Building] {
        var buildings: [Building] = []
        var id: Int64 = 1
        for i in -blocks...blocks {
            for j in -blocks...blocks {
                let e = center.east + Double(i) * 100 + 10, n = center.north + Double(j) * 100 + 10
                let corners = [
                    Walk.coordinate(east: e, north: n), Walk.coordinate(east: e + 80, north: n),
                    Walk.coordinate(east: e + 80, north: n + 80), Walk.coordinate(east: e, north: n + 80),
                ].map(WebMercator.project)
                buildings.append(Building(id: id, footprint: WorldPolygon(exterior: corners), height: height))
                id += 1
            }
        }
        return buildings
    }

    /// Every data tile within 3 km of the origin.
    var allDataTiles: [TileKey] {
        let box = GeoBoundingBox(center: Walk.origin, radius: 3_000)
        return Array(TileRange(covering: box, zoom: DataGrid.zoom))
    }

    func record(_ samples: [LocationSample], engine: DiscoveryEngine, store: InMemoryDataStore) async throws -> [DiscoveryUpdate] {
        await store.addSamples(samples)
        var updates: [DiscoveryUpdate] = []
        for sample in samples { updates.append(try await engine.process(sample)) }
        return updates
    }

    /// A full rebuild of the same samples with the same model, for comparison.
    func rebuilt(_ model: any DiscoveryModel, samples: [LocationSample]) async throws -> (DiscoveredAreaSnapshot, DataVersions) {
        let store = InMemoryDataStore()
        let engine = DiscoveryEngine(model: model, store: store)
        try await engine.rebuild(from: samples)
        return (await engine.snapshot(), try await store.dataVersions(layer: model.layer))
    }

    /// Same pieces (geometry and dates) and the same partition into regions.
    func assertEquivalent(_ a: DiscoveredAreaSnapshot, _ b: DiscoveredAreaSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(a.piecesByTile.keys), Set(b.piecesByTile.keys), "same tiles", file: file, line: line)
        struct Shape: Hashable { var tile: TileKey; var polygon: WorldPolygon; var first: Date; var last: Date }
        func shapes(_ snapshot: DiscoveredAreaSnapshot) -> [UUID: Set<Shape>] {
            var regions: [UUID: Set<Shape>] = [:]
            for pieces in snapshot.piecesByTile.values {
                for piece in pieces {
                    regions[piece.regionID, default: []].insert(Shape(
                        tile: piece.tile, polygon: piece.polygon, first: piece.firstDiscovered, last: piece.lastUpdated
                    ))
                }
            }
            return regions
        }
        let (shapesA, shapesB) = (shapes(a), shapes(b))
        XCTAssertEqual(Set(shapesA.values.flatMap { $0 }), Set(shapesB.values.flatMap { $0 }), "identical pieces", file: file, line: line)
        XCTAssertEqual(Set(shapesA.values), Set(shapesB.values), "identical regions", file: file, line: line)
        XCTAssertEqual(a.totalAreaSquareMeters, b.totalAreaSquareMeters, accuracy: 1e-6, file: file, line: line)
    }

    // MARK: The default map where data is missing

    func testDefaultMapWhereNoBuildingDataIsAvailable() async throws {
        let source = VersionedBuildingSource()
        let model = ViewshedDiscoveryModel(buildings: source)
        let sample = Walk.sample(east: 0, north: 0, second: 0)
        let tiles = try XCTUnwrap(model.dataTiles(for: sample))

        let offline = try await model.revelation(for: sample)
        XCTAssertEqual(offline.polygons.areaSquareMeters, .pi * 50 * 50, accuracy: 0.01 * .pi * 50 * 50, "the 2D circle")
        XCTAssertEqual(Set(offline.dataVersions.keys), Set(tiles))
        XCTAssertTrue(offline.dataVersions.values.allSatisfy { $0 == DataGrid.noData })

        source.publish([], tiles: Array(tiles), version: "v1")
        let online = try await model.revelation(for: sample)
        XCTAssertEqual(online.polygons.areaSquareMeters, .pi * 150 * 150, accuracy: 0.01 * .pi * 150 * 150, "open field: full view")
        XCTAssertTrue(online.dataVersions.values.allSatisfy { $0 == "v1" })
    }

    func testDataTileBorderCombinesViewshedAndDefaultMap() async throws {
        let tile = TileKey(containing: Walk.origin, zoom: DataGrid.zoom)
        let neighbour = TileKey(zoom: tile.zoom, x: tile.x + 1, y: tile.y)
        let border = offset(of: WorldPoint(x: tile.worldRect.maxX, y: tile.worldRect.center.y))
        let at = (east: border.east - 40, north: border.north)
        let source = VersionedBuildingSource()
        source.publish([], tiles: [tile], version: "v1")
        let model = ViewshedDiscoveryModel(buildings: source)
        let sample = Walk.sample(east: at.east, north: at.north, second: 0)
        let revelation = try await model.revelation(for: sample)
        func visible(east: Double) -> Bool {
            revelation.polygons.contains { $0.contains(point(east: at.east + east, north: at.north)) }
        }
        XCTAssertTrue(visible(east: -120), "data tile: the viewshed reaches 150 m")
        XCTAssertTrue(visible(east: 45), "no data: the 50 m circle")
        XCTAssertFalse(visible(east: 100), "no data: nothing beyond the circle")
        XCTAssertEqual(revelation.dataVersions[tile], "v1")
        XCTAssertEqual(revelation.dataVersions[neighbour], DataGrid.noData)
    }

    // MARK: Watermarks

    func testWatermarksRecordTheDataResultsWereComputedFrom() async throws {
        let store = InMemoryDataStore()
        let source = VersionedBuildingSource()
        let model = ViewshedDiscoveryModel(buildings: source)
        let engine = DiscoveryEngine(model: model, store: store)
        let first = Walk.sample(east: 0, north: 0, second: 0)
        let tiles = Set(try XCTUnwrap(model.dataTiles(for: first)))

        let updates = try await record([first], engine: engine, store: store)
        XCTAssertTrue(updates[0].staleDataTiles.isEmpty)
        var marks = try await store.dataVersions(layer: engine.layer)
        XCTAssertEqual(marks, Dictionary(uniqueKeysWithValues: tiles.map { ($0, DataGrid.noData) }))
        var stale = try await engine.staleDataTiles()
        XCTAssertTrue(stale.isEmpty)

        // Data arrives for one tile: it is stale until refreshed.
        let tile = TileKey(containing: Walk.origin, zoom: DataGrid.zoom)
        source.publish(cityGrid(), tiles: [tile], version: "v1")
        stale = try await engine.staleDataTiles()
        XCTAssertEqual(stale, [tile])

        // A new sample seeing the new data reports the tile; the watermark stays.
        let second = try await record([Walk.sample(east: 0, north: 30, second: 10)], engine: engine, store: store)
        XCTAssertEqual(second[0].staleDataTiles, [tile])
        marks = try await store.dataVersions(layer: engine.layer)
        XCTAssertEqual(marks[tile], DataGrid.noData)

        // Layers without map data have no watermarks.
        let circle = DiscoveryEngine(model: CircleDiscoveryModel(), store: store)
        try await circle.process(first)
        let circleMarks = try await store.dataVersions(layer: circle.layer)
        XCTAssertTrue(circleMarks.isEmpty)
        let circleStale = try await circle.staleDataTiles()
        XCTAssertTrue(circleStale.isEmpty)
    }

    // MARK: Refresh

    func testRefreshAfterDownloadEqualsFullRebuild() async throws {
        let store = InMemoryDataStore()
        let source = VersionedBuildingSource()
        let model = ViewshedDiscoveryModel(buildings: source)
        let engine = DiscoveryEngine(model: model, store: store)
        let samples = Walk.line(fromEast: -300, north: 0, toEast: 300, north: 0, step: 25)
            + Walk.line(fromEast: 0, north: -300, toEast: 0, north: 300, step: 25, startSecond: 100)
        _ = try await record(samples, engine: engine, store: store)
        let before = await engine.snapshot()

        // Entering the city without data revealed circles; now the buildings are downloaded.
        source.publish(cityGrid(), tiles: allDataTiles, version: "download:1")
        let stale = try await engine.staleDataTiles()
        XCTAssertFalse(stale.isEmpty)
        let refresh = try await engine.refresh(dataTiles: stale, locations: store)
        XCTAssertEqual(refresh.affectedSamples, samples.count)
        XCTAssertTrue(refresh.staleDataTiles.isEmpty)
        let staleAfter = try await engine.staleDataTiles()
        XCTAssertTrue(staleAfter.isEmpty)

        let after = await engine.snapshot()
        XCTAssertNotEqual(after.totalAreaSquareMeters, before.totalAreaSquareMeters, accuracy: 1)
        let (expected, expectedMarks) = try await rebuilt(model, samples: samples)
        assertEquivalent(after, expected)
        let marks = try await store.dataVersions(layer: engine.layer)
        XCTAssertEqual(marks, expectedMarks)
        // The store holds exactly what the engine holds.
        let reloaded = DiscoveryEngine(model: model, store: store)
        try await reloaded.loadAll()
        assertEquivalent(await reloaded.snapshot(), after)
        XCTAssertEqual(Set(after.regions.map(\.id)), Set(before.regions.map(\.id)), "the region keeps its ID")
    }

    func testRefreshIsLocalToTheChangedData() async throws {
        let store = InMemoryDataStore()
        let source = VersionedBuildingSource()
        let model = ViewshedDiscoveryModel(buildings: source)
        let engine = DiscoveryEngine(model: model, store: store)
        // Two walks 6 km apart: different data tiles, windows far apart.
        let far = Walk.coordinate(east: 6_000, north: 0)
        let walkA = Walk.line(fromEast: -100, north: 0, toEast: 100, north: 0, step: 25)
        let walkB = Walk.line(fromEast: -100, north: 0, toEast: 100, north: 0, step: 25, startSecond: 100, base: far)
        _ = try await record(walkA + walkB, engine: engine, store: store)
        let piecesB = await engine.snapshot().pieces(intersecting: WebMercator.worldRect(for: GeoBoundingBox(center: far, radius: 500)))
        XCTAssertFalse(piecesB.isEmpty)

        let tilesA = Set(walkA.flatMap { Array(model.dataTiles(for: $0)!) })
        source.publish(cityGrid(), tiles: Array(tilesA), version: "download:1")
        let stale = try await engine.staleDataTiles()
        XCTAssertEqual(stale, tilesA)
        let calls = source.coverageCalls
        let refresh = try await engine.refresh(dataTiles: stale, locations: store)
        XCTAssertEqual(refresh.affectedSamples, walkA.count)
        XCTAssertEqual(refresh.recomputedSamples, walkA.count, "walk B is not recomputed")
        XCTAssertEqual(source.coverageCalls - calls, walkA.count)

        let after = await engine.snapshot()
        let piecesBAfter = after.pieces(intersecting: WebMercator.worldRect(for: GeoBoundingBox(center: far, radius: 500)))
        XCTAssertEqual(Set(piecesBAfter), Set(piecesB), "untouched pieces keep their IDs")
        let (expected, _) = try await rebuilt(model, samples: walkA + walkB)
        assertEquivalent(after, expected)
    }

    func testRefreshAtTheEdgeOfTheChangedDataRederivesNeighbours() async throws {
        // A walk across a data-tile border; only the western tile gets data. The
        // samples east of the border see into the western tile and are affected;
        // samples further east are only recomputed where they overlap cleared tiles.
        let tile = TileKey(containing: Walk.origin, zoom: DataGrid.zoom)
        let border = offset(of: WorldPoint(x: tile.worldRect.maxX, y: tile.worldRect.center.y))
        let store = InMemoryDataStore()
        let source = VersionedBuildingSource()
        let model = ViewshedDiscoveryModel(buildings: source)
        let engine = DiscoveryEngine(model: model, store: store)
        let samples = Walk.line(
            fromEast: border.east - 400, north: border.north, toEast: border.east + 1_600, north: border.north, step: 40
        )
        _ = try await record(samples, engine: engine, store: store)
        source.publish(cityGrid(around: (border.east - 600, border.north), blocks: 6), tiles: [tile], version: "download:1")
        let refresh = try await engine.refresh(dataTiles: [tile], locations: store)
        XCTAssertLessThan(refresh.affectedSamples, samples.count)
        XCTAssertGreaterThan(refresh.recomputedSamples, refresh.affectedSamples)
        XCTAssertLessThan(refresh.recomputedSamples, samples.count)
        let (expected, expectedMarks) = try await rebuilt(model, samples: samples)
        assertEquivalent(await engine.snapshot(), expected)
        let marks = try await store.dataVersions(layer: engine.layer)
        XCTAssertEqual(marks, expectedMarks)
    }

    func testRefreshSplitsARegionAndTheOlderPartKeepsItsID() async throws {
        // Without data, two 100 m circles 150 m apart overlap; with data, the
        // 40 m viewsheds of an open field do not.
        var configuration = ViewshedConfiguration()
        configuration.fallbackRadius = 100
        configuration.baseDistance = 40
        let store = InMemoryDataStore()
        let source = VersionedBuildingSource()
        let model = ViewshedDiscoveryModel(buildings: source, configuration: configuration)
        let engine = DiscoveryEngine(model: model, store: store)
        let samples = [Walk.sample(east: 0, north: 0, second: 0), Walk.sample(east: 150, north: 0, second: 10)]
        _ = try await record(samples, engine: engine, store: store)
        let before = await engine.snapshot()
        XCTAssertEqual(before.regions.count, 1)
        let original = try XCTUnwrap(before.regions.first?.id)

        source.publish([], tiles: allDataTiles, version: "download:1")
        let refresh = try await engine.refresh(dataTiles: try await engine.staleDataTiles(), locations: store)
        let after = await engine.snapshot()
        XCTAssertEqual(after.regions.count, 2)
        XCTAssertEqual(after.region(at: point(east: 0, north: 0)), original, "the older part keeps the ID")
        let split = try XCTUnwrap(after.region(at: point(east: 150, north: 0)))
        XCTAssertNotEqual(split, original)
        XCTAssertEqual(refresh.createdRegionIDs, [split])
        let (expected, _) = try await rebuilt(model, samples: samples)
        assertEquivalent(after, expected)
        let regions = try await store.regions(layer: engine.layer)
        XCTAssertEqual(Set(regions.map(\.id)), [original, split])
    }

    func testRefreshMergesRegionsAndTheOlderOneSurvives() async throws {
        // Without data, two 20 m circles 150 m apart are separate; with data, the
        // 150 m viewsheds of an open field overlap.
        var configuration = ViewshedConfiguration()
        configuration.fallbackRadius = 20
        let store = InMemoryDataStore()
        let source = VersionedBuildingSource()
        let model = ViewshedDiscoveryModel(buildings: source, configuration: configuration)
        let engine = DiscoveryEngine(model: model, store: store)
        let samples = [Walk.sample(east: 0, north: 0, second: 0), Walk.sample(east: 150, north: 0, second: 10)]
        _ = try await record(samples, engine: engine, store: store)
        let before = await engine.snapshot()
        XCTAssertEqual(before.regions.count, 2)
        let older = try XCTUnwrap(before.region(at: point(east: 0, north: 0)))
        let younger = try XCTUnwrap(before.region(at: point(east: 150, north: 0)))

        source.publish([], tiles: allDataTiles, version: "download:1")
        let refresh = try await engine.refresh(dataTiles: try await engine.staleDataTiles(), locations: store)
        let after = await engine.snapshot()
        XCTAssertEqual(after.regions.map(\.id), [older])
        XCTAssertEqual(refresh.removedRegionIDs, [younger])
        let (expected, _) = try await rebuilt(model, samples: samples)
        assertEquivalent(after, expected)
    }

    func testSamplesRecordedDuringARefreshAreKept() async throws {
        let store = InMemoryDataStore()
        let source = VersionedBuildingSource()
        let model = ViewshedDiscoveryModel(buildings: source)
        let engine = DiscoveryEngine(model: model, store: store)
        let early = Walk.line(fromEast: -200, north: 0, toEast: 200, north: 0, step: 25)
        _ = try await record(early, engine: engine, store: store)
        source.publish(cityGrid(), tiles: allDataTiles, version: "download:1")
        source.delayNanoseconds = 2_000_000

        let stale = try await engine.staleDataTiles()
        let refresh = Task { try await engine.refresh(dataTiles: stale, locations: store) }
        let late = Walk.line(fromEast: 0, north: 25, toEast: 0, north: 200, step: 25, startSecond: 100)
        var lateUpdates: [DiscoveryUpdate] = []
        for sample in late {
            try await Task.sleep(nanoseconds: 3_000_000)
            lateUpdates += try await record([sample], engine: engine, store: store)
        }
        let result = try await refresh.value
        XCTAssertTrue(result.staleDataTiles.isEmpty)
        XCTAssertGreaterThan(lateUpdates.count, 0)

        let (expected, expectedMarks) = try await rebuilt(model, samples: early + late)
        assertEquivalent(await engine.snapshot(), expected)
        let reloaded = DiscoveryEngine(model: model, store: store)
        try await reloaded.loadAll()
        assertEquivalent(await reloaded.snapshot(), expected)
        let marks = try await store.dataVersions(layer: engine.layer)
        XCTAssertEqual(marks, expectedMarks)
    }

    func testRebuildReportsDataThatChangedMeanwhile() async throws {
        let source = VersionedBuildingSource()
        let model = ViewshedDiscoveryModel(buildings: source)
        let store = InMemoryDataStore()
        let engine = DiscoveryEngine(model: model, store: store)
        let samples = Walk.line(fromEast: -100, north: 0, toEast: 100, north: 0, step: 50)
        let stale = try await engine.rebuild(from: samples) { done, _ in
            if done == 2 { source.publish([], tiles: self.allDataTiles, version: "download:1") }
        }
        XCTAssertFalse(stale.isEmpty, "later samples saw newer data than earlier ones")
        let refresh = try await engine.refresh(dataTiles: stale, locations: store)
        XCTAssertEqual(refresh.affectedSamples, 0, "samples were not stored in this test")
        let staleAfter = try await engine.staleDataTiles()
        XCTAssertTrue(staleAfter.isEmpty)
    }

    // MARK: Data sources

    func testCachingSourceReportsVersionsAndDataChanges() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
        }
        final class Changes: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Set<TileKey>] = []
            func append(_ tiles: Set<TileKey>) { lock.withLock { values.append(tiles) } }
            var all: [Set<TileKey>] { lock.withLock { values } }
        }
        let online = Flag()
        let changes = Changes()
        let source = CachingBuildingSource(
            cache: InMemoryBuildingCache(),
            download: { _ in
                guard online.isSet else { throw BuildingSourceError.unavailable("offline") }
                return []
            },
            retryInterval: 0
        )
        await source.setOnDataChange { changes.append($0) }
        let tile = TileKey(containing: Walk.origin, zoom: DataGrid.zoom)
        let rect = WebMercator.worldRect(for: GeoBoundingBox(center: Walk.origin, radius: 10))
        XCTAssertEqual(Array(TileRange(covering: rect, zoom: DataGrid.zoom)), [tile])

        var coverage = await source.coverage(in: rect)
        XCTAssertEqual(coverage.versions, [tile: DataGrid.noData], "offline: no data")
        online.isSet = true
        var versions = await source.dataVersions(of: [tile], fetchingMissing: false)
        XCTAssertEqual(versions, [tile: DataGrid.noData], "nothing is downloaded unless asked")
        versions = await source.dataVersions(of: [tile], fetchingMissing: true)
        XCTAssertEqual(versions, [tile: "memory:1"])
        XCTAssertEqual(changes.all, [[tile]], "downloads are reported")
        coverage = await source.coverage(in: rect)
        XCTAssertEqual(coverage.versions, [tile: "memory:1"])
        XCTAssertEqual(changes.all.count, 1, "cached data is not a change")
    }

    func testAutomaticDownloadsCanBeTurnedOff() async throws {
        let counter = DownloadCounter()
        let source = CachingBuildingSource(
            cache: InMemoryBuildingCache(),
            download: { _ in
                await counter.increment()
                return []
            },
            downloadsAutomatically: false
        )
        let tile = TileKey(containing: Walk.origin, zoom: DataGrid.zoom)
        let rect = WebMercator.worldRect(for: GeoBoundingBox(center: Walk.origin, radius: 10))
        let coverage = await source.coverage(in: rect)
        XCTAssertEqual(coverage.versions, [tile: DataGrid.noData], "the default map, no download")
        var downloads = await counter.value
        XCTAssertEqual(downloads, 0)
        let versions = await source.dataVersions(of: [tile], fetchingMissing: true)
        XCTAssertEqual(versions, [tile: "memory:1"], "explicit requests download")
        downloads = await counter.value
        XCTAssertEqual(downloads, 1)
    }

    func testLayeredCachePrefersTheBundledVersion() async throws {
        let tile = TileKey(containing: Walk.origin, zoom: DataGrid.zoom)
        let other = TileKey(zoom: tile.zoom, x: tile.x + 1, y: tile.y)
        let base = InMemoryBuildingCache([], downloadedTiles: [tile])
        let overlay = InMemoryBuildingCache()
        try await overlay.store([], downloadedTiles: [tile, other])
        let layered = LayeredBuildingCache(overlay: overlay) { base }
        let bundled = try await layered.version(of: tile)
        let downloaded = try await layered.version(of: other)
        let missing = try await layered.version(of: TileKey(zoom: tile.zoom, x: tile.x + 2, y: tile.y))
        XCTAssertEqual(bundled, "bundle:memory:0")
        XCTAssertEqual(downloaded, "download:memory:1")
        XCTAssertNil(missing)
    }

    func testRecorderKeepsRecordingOfflineWithTheDefaultMap() async throws {
        let store = InMemoryDataStore()
        let source = CachingBuildingSource(
            cache: InMemoryBuildingCache(),
            download: { _ in throw BuildingSourceError.unavailable("offline") }
        )
        let engine = DiscoveryEngine(model: ViewshedDiscoveryModel(buildings: source), store: store)
        let recorder = LocationRecorder(store: store, engines: [engine])
        let outcome = try await recorder.record(Walk.sample(east: 0, north: 0, second: 0))
        XCTAssertTrue(outcome.isRecorded)
        let stale = await recorder.staleLayers
        XCTAssertTrue(stale.isEmpty, "the layer is complete: it used the default map")
        let area = await engine.snapshot().totalAreaSquareMeters
        XCTAssertEqual(area, .pi * 50 * 50, accuracy: 0.01 * .pi * 50 * 50)
    }
}
