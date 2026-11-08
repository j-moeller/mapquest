import XCTest
@testable import MapQuestCore
import MapQuestTestSupport

final class TrackTests: XCTestCase {
    func testQuantizationIsFarBelowGNSSAccuracy() {
        let date = Date(timeIntervalSince1970: 1_760_000_000.37)
        let point = TrackPoint(
            timestamp: date, latitude: 52.520_008_7, longitude: 13.404_954_3, altitude: 36.27,
            horizontalAccuracy: 4.66, verticalAccuracy: -1
        )
        XCTAssertEqual(point.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.05)
        XCTAssertEqual(point.coordinate.distance(to: GeoCoordinate(latitude: 52.520_008_7, longitude: 13.404_954_3)), 0, accuracy: 0.1)
        XCTAssertEqual(point.altitude, 36.3, accuracy: 1e-9)
        XCTAssertEqual(point.horizontalAccuracy, 4.7, accuracy: 1e-9)
        XCTAssertEqual(point.verticalAccuracy, -1)
        XCTAssertTrue(point.hasValidPosition)
        XCTAssertEqual(point.sample.id, point.sample.id, "stable sample IDs")
        XCTAssertNotEqual(point.sample.id, TrackPoint(time: point.time + 1, latitudeE6: 0, longitudeE6: 0, altitudeDM: 0, horizontalAccuracyDM: 0, verticalAccuracyDM: 0).sample.id)
    }

    func testCodecRoundTripsExactlyIncludingExtremes() throws {
        var points = DataStoreContract.makeTrack(count: 500)
        points.append(TrackPoint(time: points.last!.time + 36_000, latitudeE6: -89_999_999, longitudeE6: 179_999_999, altitudeDM: -4_000, horizontalAccuracyDM: -1, verticalAccuracyDM: 9_999))
        points.append(TrackPoint(time: points.last!.time + 1, latitudeE6: 89_000_000, longitudeE6: -180_000_000, altitudeDM: 88_480, horizontalAccuracyDM: 0, verticalAccuracyDM: -1))
        let data = TrackCodec.encode(points)
        XCTAssertEqual(try TrackCodec.decode(data), points)
        XCTAssertEqual(try TrackCodec.decode(TrackCodec.encode([])), [])
        XCTAssertThrowsError(try TrackCodec.decode(data.prefix(data.count - 3)))
        XCTAssertThrowsError(try TrackCodec.decode(Data([9, 0])))
    }

    func testOneHertzWalkingNeedsAboutSevenBytesPerFix() {
        // An hour on foot at 1 Hz with GNSS noise: ≈ 1.4 m/s, accuracy 3–8 m.
        var generator = SplitMix(seed: 7)
        var points: [TrackPoint] = []
        var lat = 52.52, lon = 13.405, alt = 36.0
        for i in 0..<3_600 {
            lat += 1.4 * cos(Double(i) / 300) / 111_320 + generator.noise(0.4) / 111_320
            lon += 1.4 * sin(Double(i) / 300) / 67_800 + generator.noise(0.4) / 67_800
            alt += generator.noise(0.3)
            points.append(TrackPoint(
                timestamp: Date(timeIntervalSince1970: 1_760_000_000 + Double(i) + generator.noise(0.05)),
                latitude: lat, longitude: lon, altitude: alt,
                horizontalAccuracy: 5 + generator.noise(2), verticalAccuracy: 4 + generator.noise(1)
            ))
        }
        let segments = stride(from: 0, to: points.count, by: 600).map { TrackSegment(points: Array(points[$0..<min($0 + 600, points.count)])) }
        let bytes = segments.reduce(0) { $0 + $1.data.count }
        let perFix = Double(bytes) / Double(points.count)
        XCTAssertLessThan(perFix, 9, "delta-encoded fixes stay small")
        print("track: \(bytes) bytes for \(points.count) fixes = \(String(format: "%.2f", perFix)) bytes per fix")
    }

    func testWriterBuffersFlushesAndSplitsSegments() async throws {
        let store = InMemoryDataStore()
        let writer = TrackWriter(store: store, configuration: .init(maximumSegmentPoints: 100, maximumGap: 60, flushPoints: 30, flushInterval: 30))
        let walk = DataStoreContract.makeTrack(count: 250)
        var kept = 0
        for point in walk {
            if try await writer.append(point) { kept += 1 }
        }
        XCTAssertEqual(kept, 250)
        // Too frequent and invalid fixes are dropped.
        var duplicate = walk.last!
        duplicate.time += 3
        let tooSoon = try await writer.append(duplicate)
        XCTAssertFalse(tooSoon)
        var invalid = walk.last!
        invalid.time += 20
        invalid.horizontalAccuracyDM = -1
        let rejected = try await writer.append(invalid)
        XCTAssertFalse(rejected)

        var summary = await store.trackSummary()
        XCTAssertLessThan(summary.pointCount, 250, "the open segment's tail is still buffered")
        XCTAssertGreaterThanOrEqual(summary.pointCount, 220)
        try await writer.flush()
        summary = await store.trackSummary()
        XCTAssertEqual(summary.pointCount, 250)
        XCTAssertEqual(summary.segmentCount, 3, "segments of at most 100 fixes")
        let stored = try await store.trackPoints()
        XCTAssertEqual(stored, walk)

        // A pause longer than the maximum gap starts a new segment.
        let later = DataStoreContract.makeTrack(count: 5, from: walk.last!.timestamp.addingTimeInterval(600))
        for point in later { try await writer.append(point) }
        try await writer.flush()
        summary = await store.trackSummary()
        XCTAssertEqual(summary.segmentCount, 4)
        XCTAssertEqual(summary.pointCount, 255)
    }

    func testRecorderStoresEveryFixInTheTrack() async throws {
        let store = InMemoryDataStore()
        let writer = TrackWriter(store: store)
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(), store: store)
        let recorder = LocationRecorder(store: store, engines: [engine], track: writer)
        // 60 s standing still, then 60 s walking: only a few fixes reveal new area,
        // but all of them are in the track.
        var fixes: [LocationSample] = (0..<60).map { Walk.sample(east: 0, north: 0, second: Double($0)) }
        fixes += (0..<60).map { Walk.sample(east: Double($0) * 1.4, north: 0, second: 60 + Double($0)) }
        for fix in fixes { _ = try await recorder.record(fix) }
        try await writer.flush()
        let track = try await store.trackPoints()
        XCTAssertEqual(track.count, fixes.count)
        let keySamples = await store.sampleCount()
        XCTAssertLessThan(keySamples, 20, "only map-changing fixes are key samples")
    }
}

/// Deterministic pseudo-random noise for tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform noise in [-amplitude, amplitude].
    mutating func noise(_ amplitude: Double) -> Double {
        (Double(next() % 1_000_000) / 500_000 - 1) * amplitude
    }
}
