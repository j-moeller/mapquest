import XCTest
@testable import MapQuestCore
import MapQuestTestSupport

final class PeriodTests: XCTestCase {
    var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2 // Monday
        calendar.minimumDaysInFirstWeek = 4 // ISO 8601
        return calendar
    }

    func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    func testCalendarPeriods() {
        let calendar = berlin
        let moment = date("2026-11-08T13:30:00+01:00") // a Sunday
        let day = Period(.day, containing: moment, calendar: calendar)
        XCTAssertEqual(day.start, date("2026-11-08T00:00:00+01:00"))
        XCTAssertEqual(day.end, date("2026-11-09T00:00:00+01:00"))
        XCTAssertEqual(day.key(calendar: calendar), "2026-11-08")
        let week = Period(.week, containing: moment, calendar: calendar)
        XCTAssertEqual(week.start, date("2026-11-02T00:00:00+01:00"), "weeks start on Monday")
        XCTAssertEqual(week.days(calendar: calendar).count, 7)
        XCTAssertEqual(week.key(calendar: calendar), "2026-W45")
        let month = Period(.month, containing: moment, calendar: calendar)
        XCTAssertEqual(month.days(calendar: calendar).count, 30)
        XCTAssertEqual(month.key(calendar: calendar), "2026-11")
        XCTAssertEqual(month.shifted(by: -1, calendar: calendar).key(calendar: calendar), "2026-10")
        XCTAssertEqual(month.shifted(by: 2, calendar: calendar).key(calendar: calendar), "2027-01")
        let year = Period(.year, containing: moment, calendar: calendar)
        XCTAssertEqual(year.days(calendar: calendar).count, 365)
        XCTAssertEqual(year.key(calendar: calendar), "2026")
        XCTAssertTrue(day.contains(moment))
        XCTAssertFalse(day.contains(day.end))
        // The day the clocks go back has 25 hours.
        let long = Period(.day, containing: date("2026-10-25T12:00:00+01:00"), calendar: calendar)
        XCTAssertEqual(long.end.timeIntervalSince(long.start), 25 * 3_600)
        XCTAssertEqual(long.shifted(by: 1, calendar: calendar).key(calendar: calendar), "2026-10-26")
    }

    // MARK: Statistics

    func testDistanceIgnoresJitterAndGaps() {
        var random = SplitMix(seed: 5)
        var points: [TrackPoint] = []
        let start = date("2026-11-08T08:00:00+01:00")
        // 1 km east at 1.4 m/s with ±2 m noise, then an hour standing still with ±6 m jitter.
        let walkSeconds = Int(1_000 / 1.4)
        for i in 0...walkSeconds {
            let c = Walk.coordinate(east: Double(i) * 1.4 + random.noise(2), north: random.noise(2))
            points.append(TrackPoint(timestamp: start.addingTimeInterval(Double(i)), latitude: c.latitude, longitude: c.longitude, altitude: 40, horizontalAccuracy: 5, verticalAccuracy: 4))
        }
        for i in 1...3_600 {
            let c = Walk.coordinate(east: 1_000 + random.noise(6), north: random.noise(6))
            points.append(TrackPoint(timestamp: start.addingTimeInterval(Double(walkSeconds + i)), latitude: c.latitude, longitude: c.longitude, altitude: 40, horizontalAccuracy: 10, verticalAccuracy: 4))
        }
        let statistics = TrackStatistics.of(points, calendar: berlin)
        XCTAssertEqual(statistics.distanceMeters, 1_000, accuracy: 40)
        XCTAssertEqual(statistics.recordedSeconds, Double(points.count), accuracy: 2)
        XCTAssertEqual(statistics.activeDays, 1)
        XCTAssertEqual(statistics.fixes, points.count)
    }

    // MARK: Period areas

    /// Two walks on 7 and 8 November (the 8th is "today", until 14:00).
    func makeStore() async throws -> (InMemoryDataStore, Date) {
        let store = InMemoryDataStore()
        let first = date("2026-11-07T10:00:00+01:00")
        let second = date("2026-11-08T10:00:00+01:00")
        var points = DataStoreContract.makeTrack(count: 900, from: first)
        points += DataStoreContract.makeTrack(count: 600, from: second, longitude: 13.3950)
        let writer = TrackWriter(store: store)
        for point in points { try await writer.append(point) }
        try await writer.flush()
        return (store, date("2026-11-08T14:00:00+01:00"))
    }

    func testAreaOfADayIsComputedFromItsSampledTrackAndCached() async throws {
        let (store, now) = try await makeStore()
        let discovery = PeriodDiscovery(store: store, calendar: berlin, now: { now })
        let counting = CountingModel()
        let yesterday = Period(.day, containing: date("2026-11-07T12:00:00+01:00"), calendar: berlin)
        let area = try await discovery.area(of: yesterday, model: counting)
        XCTAssertEqual(area.statistics.fixes, 900)
        XCTAssertGreaterThan(area.evaluatedFixes, 10)
        XCTAssertLessThan(area.evaluatedFixes, 900 / 4, "sampled")
        XCTAssertEqual(counting.evaluations, area.evaluatedFixes)
        // ≈ 900 s × 1.4 m/s … the fixture walks ≈ 1.2 km: a 100 m wide corridor.
        XCTAssertGreaterThan(area.snapshot.totalAreaSquareMeters, 100_000)
        let layers = await store.layers()
        XCTAssertTrue(layers.contains(discovery.dayLayer(yesterday, model: counting, sampling: .init())), "completed days are cached")

        let again = try await discovery.area(of: yesterday, model: counting)
        XCTAssertEqual(counting.evaluations, area.evaluatedFixes, "no recomputation")
        XCTAssertEqual(again.snapshot.totalAreaSquareMeters, area.snapshot.totalAreaSquareMeters, accuracy: 1e-6)

        // Compared with all fixes: the sampled area is the same within the sampler's bound.
        let all = try await store.trackPoints(in: DateInterval(start: yesterday.start, end: yesterday.end))
        let full = InMemoryDataStore()
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(), store: full)
        try await engine.rebuild(from: all.map(\.sample))
        let exact = await engine.snapshot().totalAreaSquareMeters
        XCTAssertEqual(area.snapshot.totalAreaSquareMeters, exact, accuracy: exact * 0.01)
    }

    func testTodayIsRecomputedWhenTheTrackGrows() async throws {
        let (store, now) = try await makeStore()
        let discovery = PeriodDiscovery(store: store, calendar: berlin, now: { now })
        let model = CountingModel()
        let today = Period(.day, containing: now, calendar: berlin)
        let before = try await discovery.area(of: today, model: model)
        let evaluations = model.evaluations
        _ = try await discovery.area(of: today, model: model)
        XCTAssertEqual(model.evaluations, evaluations, "unchanged track: cached in memory")
        let layers = await store.layers()
        XCTAssertFalse(layers.contains(discovery.dayLayer(today, model: model, sampling: .init())), "today is not persisted")
        try await store.putTrackSegments([TrackSegment(points: DataStoreContract.makeTrack(count: 300, from: date("2026-11-08T12:00:00+01:00"), longitude: 13.4100))])
        let after = try await discovery.area(of: today, model: model)
        XCTAssertGreaterThan(model.evaluations, evaluations)
        XCTAssertGreaterThan(after.snapshot.totalAreaSquareMeters, before.snapshot.totalAreaSquareMeters)
    }

    func testWeekIsTheUnionOfItsDays() async throws {
        let (store, now) = try await makeStore()
        let discovery = PeriodDiscovery(store: store, calendar: berlin, now: { now })
        let model = CircleDiscoveryModel()
        let week = Period(.week, containing: now, calendar: berlin)
        var progress: [Int] = []
        let lock = NSLock()
        let area = try await discovery.area(of: week, model: model) { done, _ in lock.withLock { progress.append(done) } }
        XCTAssertEqual(area.days.count, 2, "only days with track data")
        XCTAssertEqual(lock.withLock { progress }, [1, 2])
        let day1 = try await discovery.area(of: Period(.day, containing: date("2026-11-07T12:00:00+01:00"), calendar: berlin), model: model)
        let day2 = try await discovery.area(of: Period(.day, containing: now, calendar: berlin), model: model)
        // The walks overlap partly: the union is less than the sum and more than either.
        let union = area.snapshot.totalAreaSquareMeters
        XCTAssertLessThan(union, day1.snapshot.totalAreaSquareMeters + day2.snapshot.totalAreaSquareMeters)
        XCTAssertGreaterThan(union, max(day1.snapshot.totalAreaSquareMeters, day2.snapshot.totalAreaSquareMeters))
        XCTAssertEqual(area.statistics.fixes, 1_500)
        XCTAssertEqual(area.statistics.activeDays, 2)
        let month = try await discovery.area(of: Period(.month, containing: now, calendar: berlin), model: model)
        XCTAssertEqual(month.snapshot.totalAreaSquareMeters, union, accuracy: 1e-3)
        let empty = try await discovery.area(of: Period(.month, containing: date("2026-07-01T12:00:00+02:00"), calendar: berlin), model: model)
        XCTAssertEqual(empty.snapshot.totalAreaSquareMeters, 0)
        XCTAssertEqual(empty.statistics.fixes, 0)
    }

    func testCachedDaysFollowNewBuildingData() async throws {
        let (store, now) = try await makeStore()
        let discovery = PeriodDiscovery(store: store, calendar: berlin, now: { now })
        let source = VersionedBuildingSource()
        let model = ViewshedDiscoveryModel(buildings: source)
        let yesterday = Period(.day, containing: date("2026-11-07T12:00:00+01:00"), calendar: berlin)
        let offline = try await discovery.area(of: yesterday, model: model)
        XCTAssertGreaterThan(offline.evaluatedFixes, 0)
        let cached = try await discovery.area(of: yesterday, model: model)
        XCTAssertEqual(cached.evaluatedFixes, 0, "served from the cache")
        // Building data arrives: the cached day is stale and recomputed (open field: 150 m views).
        let box = GeoBoundingBox(center: GeoCoordinate(latitude: 52.517, longitude: 13.385), radius: 3_000)
        source.publish([], tiles: Array(TileRange(covering: box, zoom: DataGrid.zoom)), version: "download:1")
        let online = try await discovery.area(of: yesterday, model: model)
        XCTAssertGreaterThan(online.evaluatedFixes, 0, "recomputed")
        XCTAssertGreaterThan(online.snapshot.totalAreaSquareMeters, offline.snapshot.totalAreaSquareMeters * 2)
    }

    // MARK: Heatmap

    func testHeatmapCountsTimeSpentAndBlurs() {
        let center = WebMercator.project(Walk.origin)
        let unitsPerMeter = 1 / WebMercator.metersPerUnit(atLatitude: Walk.origin.latitude)
        let cell = Int64((10 * unitsPerMeter).rounded())
        let rect = WorldRect(minX: center.x - 50 * cell, minY: center.y - 50 * cell, maxX: center.x + 50 * cell, maxY: center.y + 50 * cell)
        var grid = HeatmapGrid(covering: rect, cellSize: cell)
        XCTAssertEqual(grid.columns, 100)
        XCTAssertEqual(grid.rows, 100)
        // 10 minutes at the centre, then a quick walk east; a fix with poor accuracy is ignored.
        var points: [TrackPoint] = (0..<600).map { i in
            TrackPoint(timestamp: Date(timeIntervalSince1970: 1_760_000_000 + Double(i)), latitude: Walk.origin.latitude, longitude: Walk.origin.longitude, altitude: 40, horizontalAccuracy: 5, verticalAccuracy: 3)
        }
        for i in 1...30 {
            let c = Walk.coordinate(east: Double(i) * 10, north: 0)
            points.append(TrackPoint(timestamp: Date(timeIntervalSince1970: 1_760_000_600 + Double(i) * 7), latitude: c.latitude, longitude: c.longitude, altitude: 40, horizontalAccuracy: i == 5 ? 80 : 5, verticalAccuracy: 3))
        }
        grid.add(points)
        // Seconds until the next fix, capped at 5 s: 599 × 1 s + 5 s at the centre, 28 × 5 s on the
        // walk (the inaccurate fix is skipped), 1 s for the last fix.
        XCTAssertEqual(grid.total, 599 + 5 + 28 * 5 + 1, accuracy: 0.01)
        XCTAssertEqual(grid[50, 50], 604, accuracy: 0.01)
        let blurred = grid.blurred(radius: 2)
        XCTAssertEqual(blurred.total, grid.total, accuracy: grid.total * 0.001, "mass is preserved away from the edges")
        XCTAssertLessThan(blurred.maximum, grid.maximum)
        XCTAssertGreaterThan(blurred[52, 50], 0)
        let pixels = blurred.rgba()
        XCTAssertEqual(pixels.count, 100 * 100 * 4)
        XCTAssertEqual(pixels[(10 * 100 + 10) * 4 + 3], 0, "nothing there: transparent")
        let hot = pixels[(50 * 100 + 50) * 4 + 3], warm = pixels[(50 * 100 + 75) * 4 + 3]
        XCTAssertGreaterThan(hot, warm)
        XCTAssertGreaterThan(warm, 0)
        let (r, _, b, a) = HeatmapPalette.color(1)
        XCTAssertGreaterThan(r, b)
        XCTAssertGreaterThan(a, 200)
        XCTAssertEqual(HeatmapPalette.color(0).3, 0)
    }
}
