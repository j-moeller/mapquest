import Foundation

/// Decides when location tracking may save power. While the phone moves, or while
/// the app is open, positions come from GPS at full accuracy. Once the phone has
/// stayed within `stillRadius` of one place for `stillDuration` with the app in the
/// background (at home, at a desk), GPS can be switched off in favour of coarse
/// positions (Wi-Fi, cell) that arrive only after moving; the first fix away from
/// that place switches GPS back on.
///
/// Fixes count as "away" only beyond what both fixes' accuracies allow, so the
/// jitter of poor indoor fixes, or of coarse ones, does not wake GPS.
public struct StillnessDetector: Sendable {
    public enum Power: Hashable, Sendable {
        case full
        case low
    }

    public var stillRadius: Double
    public var stillDuration: TimeInterval
    public private(set) var power: Power = .full
    public private(set) var isInBackground = false

    /// Where the phone has stayed since `stillSince`.
    private var anchor: (coordinate: GeoCoordinate, accuracy: Double)?
    private var stillSince: Date?

    public init(stillRadius: Double = 25, stillDuration: TimeInterval = 180) {
        self.stillRadius = stillRadius
        self.stillDuration = stillDuration
    }

    /// The app went to the background or came back (power is full while it is open).
    @discardableResult
    public mutating func setInBackground(_ background: Bool, now: Date) -> Power {
        isInBackground = background
        if background {
            evaluate(now: now)
        } else {
            power = .full
        }
        return power
    }

    /// Follows a fix; returns the power to use from now on.
    @discardableResult
    public mutating func update(_ coordinate: GeoCoordinate, accuracy: Double, timestamp: Date) -> Power {
        guard accuracy >= 0 else { return power }
        if let anchor {
            let tolerance = max(stillRadius, accuracy + max(0, anchor.accuracy))
            if coordinate.distance(to: anchor.coordinate) <= tolerance {
                evaluate(now: timestamp)
                return power
            }
        }
        // Moving, or the first fix: a new place to stay at, with GPS on.
        anchor = (coordinate, accuracy)
        stillSince = timestamp
        power = .full
        return power
    }

    /// Forgets where the phone stayed (tracking restarted).
    public mutating func reset() {
        anchor = nil
        stillSince = nil
        power = .full
    }

    private mutating func evaluate(now: Date) {
        guard isInBackground, let stillSince, now.timeIntervalSince(stillSince) >= stillDuration else { return }
        power = .low
    }
}
