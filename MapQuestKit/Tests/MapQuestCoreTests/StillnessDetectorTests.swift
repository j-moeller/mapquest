import Foundation
import XCTest
@testable import MapQuestCore

/// When location tracking may switch GPS off: still in the background for a while.
final class StillnessDetectorTests: XCTestCase {
    private let home = GeoCoordinate(latitude: 52.5200, longitude: 13.4050)
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// A point `meters` east of home.
    private func east(_ meters: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: home.latitude, longitude: home.longitude + meters / (111_320 * cos(home.latitude * .pi / 180)))
    }

    func testStillInTheBackgroundSavesPower() {
        var detector = StillnessDetector()
        detector.setInBackground(true, now: start)
        for second in stride(from: 0, through: 170, by: 10) {
            XCTAssertEqual(detector.update(east(Double(second % 3) * 4), accuracy: 8, timestamp: start + Double(second)), .full)
        }
        XCTAssertEqual(detector.update(home, accuracy: 8, timestamp: start + 181), .low, "three minutes within 25 m")
        // Coarse positions jitter within their accuracy: still low.
        XCTAssertEqual(detector.update(east(60), accuracy: 65, timestamp: start + 400), .low)
        // Walking away: GPS again.
        XCTAssertEqual(detector.update(east(200), accuracy: 65, timestamp: start + 600), .full)
    }

    func testNeverLowWhileTheAppIsOpen() {
        var detector = StillnessDetector()
        for second in stride(from: 0, through: 600, by: 10) {
            XCTAssertEqual(detector.update(home, accuracy: 5, timestamp: start + Double(second)), .full)
        }
        XCTAssertEqual(detector.setInBackground(true, now: start + 601), .low, "still for ten minutes already")
        XCTAssertEqual(detector.setInBackground(false, now: start + 700), .full, "opened again")
    }

    func testWalkingKeepsFullPower() {
        var detector = StillnessDetector()
        detector.setInBackground(true, now: start)
        for second in 0...600 {
            // 1.4 m/s
            XCTAssertEqual(detector.update(east(Double(second) * 1.4), accuracy: 5, timestamp: start + Double(second)), .full)
        }
    }

    func testPoorIndoorFixesCountAsStill() {
        var detector = StillnessDetector()
        detector.setInBackground(true, now: start)
        detector.update(home, accuracy: 40, timestamp: start)
        // GPS indoors: fixes 30–50 m apart, each ±40 m.
        for second in stride(from: 10, through: 200, by: 10) {
            detector.update(east(second % 20 == 0 ? 45 : 30), accuracy: 40, timestamp: start + Double(second))
        }
        XCTAssertEqual(detector.power, .low)
        detector.reset()
        XCTAssertEqual(detector.power, .full)
    }
}
