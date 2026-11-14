import Foundation
import XCTest
@testable import MapQuestCore

/// The walked distance: a line through fixes close in time and space, at walking pace.
final class WalkedDistanceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let origin = GeoCoordinate(latitude: 52.5200, longitude: 13.4050)
    private var random = SystemRandomNumberGenerator()

    /// A fix `east` and `north` metres from the origin, `second`s after the start.
    private func fix(_ second: Double, east: Double, north: Double = 0, accuracy: Double = 5) -> TrackPoint {
        let lat = origin.latitude + north / 111_320
        let lon = origin.longitude + east / (111_320 * cos(origin.latitude * .pi / 180))
        return TrackPoint(LocationSample(latitude: lat, longitude: lon, altitude: 35, horizontalAccuracy: accuracy,
                                         timestamp: start + second))
    }

    private func noise(_ amplitude: Double) -> Double {
        Double.random(in: -amplitude...amplitude, using: &random)
    }

    func testAWalkCountsItsLength() {
        // Ten minutes at 1.4 m/s, a fix every second, ±2 m of GPS noise: 840 m.
        let walk = (0...600).map { fix(Double($0), east: Double($0) * 1.4 + noise(2), north: noise(2)) }
        XCTAssertEqual(TrackStatistics.walkedMeters(walk), 840, accuracy: 50)
    }

    func testStandingStillAddsNothing() {
        // Ten minutes in one place, ±3 m of jitter around a position drifting 10 m.
        let still = (0...600).map { second -> TrackPoint in
            let drift = 10 * sin(Double(second) / 600 * .pi)
            return fix(Double(second), east: drift + noise(3), north: noise(3))
        }
        XCTAssertLessThan(TrackStatistics.walkedMeters(still), 25)
    }

    func testRidesDoNotCount() {
        // A tram at 8 m/s, a bike at 5 m/s.
        let tram = (0...300).map { fix(Double($0), east: Double($0) * 8) }
        let bike = (0...300).map { fix(Double($0), east: Double($0) * 5) }
        XCTAssertEqual(TrackStatistics.walkedMeters(tram), 0)
        XCTAssertEqual(TrackStatistics.walkedMeters(bike), 0)
    }

    func testGapsAndJumpsAreNotBridged() {
        // Walk 200 s, ride the U-Bahn underground (no fixes for 6 minutes, 3 km on), walk 200 s.
        var points = (0...200).map { fix(Double($0), east: Double($0) * 1.4) }
        points += (0...200).map { fix(560 + Double($0), east: 3_000 + Double($0) * 1.4) }
        XCTAssertEqual(TrackStatistics.walkedMeters(points), 560, accuracy: 15)
        // A single GPS jump of 40 m sideways inside a walk costs a few metres, adds none.
        var jumpy = (0...300).map { fix(Double($0), east: Double($0) * 1.4) }
        jumpy[150] = fix(150, east: 150 * 1.4, north: 40)
        XCTAssertEqual(TrackStatistics.walkedMeters(jumpy), 420, accuracy: 15)
        // Inaccurate fixes (indoors) draw nothing.
        let poor = (0...300).map { fix(Double($0), east: Double($0) * 1.4, accuracy: 50) }
        XCTAssertEqual(TrackStatistics.walkedMeters(poor), 0)
    }

    func testByDayAndInStatistics() {
        let calendar = Calendar(identifier: .gregorian)
        let walk = (0...600).map { fix(Double($0), east: Double($0) * 1.4) }
        let byDay = TrackStatistics.walkedMetersByDay(walk, calendar: calendar)
        XCTAssertEqual(byDay.values.reduce(0, +), TrackStatistics.walkedMeters(walk), accuracy: 6)
        let statistics = TrackStatistics.of(walk, calendar: calendar)
        XCTAssertEqual(statistics.walkedMeters, 840, accuracy: 10)
        XCTAssertEqual(TrackStatistics.combined([statistics, statistics]).walkedMeters, statistics.walkedMeters * 2, accuracy: 0.01)
    }
}
