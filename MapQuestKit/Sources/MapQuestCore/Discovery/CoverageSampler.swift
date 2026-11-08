import Foundation

/// Reduces a stream of position fixes to the few that matter for area
/// calculations (docs/01-literature-review.md, §2.4).
///
/// At one fix per second, consecutive fixes reveal almost the same area. The
/// sampler is an *opening window* trajectory simplification (Meratnia & de By
/// 2004) adapted to coverage: starting from the last kept fix (the anchor),
/// fixes are skipped as long as
///
/// * every skipped fix lies within `tolerance(fix)` of the chord from the anchor
///   to the newest fix – the tolerance follows the fix's own accuracy (1.5 σ, at
///   least `tolerance`, at most `maximumTolerance`), so GNSS jitter while
///   standing still never counts as movement,
/// * the chord is at most `spacing` long (or the newest fix's tolerance, if
///   larger: anchor and fix may both be off by their accuracy),
/// * the altitude did not change by more than `minimumClimb` (or the vertical
///   accuracy, if larger), and
/// * the anchor is not older than `maximumDelay`.
///
/// When the window breaks, the last fix inside it is kept and becomes the new
/// anchor (unless it is within its tolerance of the anchor: mere jitter). Every
/// skipped fix therefore lies within its tolerance of the segment between two
/// kept fixes at most `spacing` apart: for a circle of radius r the union of the
/// kept circles misses at most `tolerance + r − √(r² − spacing²/4)` of the union
/// of all circles (0.25 m + tolerance for r = 50 m and 10 m spacing) – never
/// more than the fixes' own uncertainty.
///
/// Offline (`reduce`), fixes revisiting a place – within `revisitRadius` of an
/// earlier kept fix at a similar altitude – are dropped as well.
public struct CoverageSampler: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// Maximum distance between consecutive kept fixes (metres).
        public var spacing: Double
        /// Minimum tolerance for skipped fixes (metres); otherwise 1.5 × their accuracy.
        public var tolerance: Double
        /// The accuracy-dependent tolerance never exceeds this (metres).
        public var maximumTolerance: Double
        /// An altitude change of this much (or the vertical accuracy, if larger) is kept.
        public var minimumClimb: Double
        /// Less accurate fixes are ignored (metres, 1σ).
        public var maximumAccuracy: Double
        /// A fix is kept at least this often while moving (seconds).
        public var maximumDelay: TimeInterval
        /// Offline: drop fixes within this distance of an earlier kept fix (`nil`: off).
        public var revisitRadius: Double?

        public init(
            spacing: Double = 10, tolerance: Double = 3, maximumTolerance: Double = 20, minimumClimb: Double = 3,
            maximumAccuracy: Double = 50, maximumDelay: TimeInterval = 30, revisitRadius: Double? = nil
        ) {
            precondition(spacing > 0 && tolerance >= 0, "invalid sampling configuration")
            self.spacing = spacing
            self.tolerance = tolerance
            self.maximumTolerance = max(maximumTolerance, tolerance)
            self.minimumClimb = minimumClimb
            self.maximumAccuracy = maximumAccuracy
            self.maximumDelay = maximumDelay
            self.revisitRadius = revisitRadius
        }

        /// For period computations: additionally merges revisits within half the spacing.
        public var offline: Configuration {
            var configuration = self
            configuration.revisitRadius = configuration.revisitRadius ?? spacing / 2
            return configuration
        }
    }

    public let configuration: Configuration
    private var anchor: LocationSample?
    /// When the current window started (the anchor's time, or a restart while standing still).
    private var windowStart = Date.distantPast
    private var window: [LocationSample] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Adds the next fix (chronological order); returns the fixes to keep now
    /// (usually none, at most two).
    public mutating func add(_ sample: LocationSample) -> [LocationSample] {
        guard sample.hasValidPosition, sample.horizontalAccuracy <= configuration.maximumAccuracy else { return [] }
        guard let anchor else {
            start(at: sample)
            return [sample]
        }
        if fits(sample, after: anchor) {
            window.append(sample)
            return []
        }
        // The window breaks. Keep its last fix if it differs noticeably from the
        // anchor – or else the furthest one, an excursion – but not mere jitter.
        let keep = window.last.flatMap { differs($0, from: anchor) ? $0 : nil }
            ?? window.filter { differs($0, from: anchor) }.max { distance(anchor, $0) < distance(anchor, $1) }
        if let keep {
            start(at: keep)
            if fits(sample, after: keep) {
                window = [sample]
                return [keep]
            }
            start(at: sample)
            return [keep, sample]
        }
        if differs(sample, from: anchor) {
            start(at: sample)
            return [sample]
        }
        // Still at the anchor (the window only timed out): restart it.
        window = []
        windowStart = sample.timestamp
        return []
    }

    private mutating func start(at sample: LocationSample) {
        anchor = sample
        windowStart = sample.timestamp
        window = []
    }

    /// Ends the stream: keeps the last skipped fix if it differs noticeably from the anchor.
    public mutating func finish() -> [LocationSample] {
        defer {
            anchor = nil
            window = []
        }
        guard let anchor, let last = window.last else { return [] }
        return differs(last, from: anchor) ? [last] : []
    }

    private func differs(_ sample: LocationSample, from anchor: LocationSample) -> Bool {
        distance(anchor, sample) > tolerance(of: sample) || climbed(from: anchor, to: sample)
    }

    /// Reduces a whole sequence of fixes (sorted by time), dropping revisits if configured.
    public static func reduce(_ samples: [LocationSample], configuration: Configuration) -> [LocationSample] {
        var sampler = CoverageSampler(configuration: configuration)
        var kept: [LocationSample] = []
        for sample in samples { kept += sampler.add(sample) }
        kept += sampler.finish()
        guard let radius = configuration.revisitRadius, radius > 0 else { return kept }
        // Spatial hash of kept fixes; cells of `radius` metres (at the first fix's latitude).
        guard let first = kept.first else { return kept }
        let unitsPerMeter = 1 / WebMercator.metersPerUnit(atLatitude: first.latitude)
        let cell = max(Int64((radius * unitsPerMeter).rounded(.up)), 1)
        var grid: [Int64: [Int64: [LocationSample]]] = [:]
        var result: [LocationSample] = []
        let probe = CoverageSampler(configuration: configuration)
        for sample in kept {
            let p = sample.worldPoint
            let (cx, cy) = (p.x / cell, p.y / cell)
            var revisit = false
            search: for dx: Int64 in -1...1 {
                for dy: Int64 in -1...1 {
                    for other in grid[cx + dx]?[cy + dy] ?? [] where probe.distance(other, sample) <= radius && !probe.climbed(from: other, to: sample) {
                        revisit = true
                        break search
                    }
                }
            }
            guard !revisit else { continue }
            grid[cx, default: [:]][cy, default: []].append(sample)
            result.append(sample)
        }
        return result
    }

    // MARK: Geometry (local metres)

    private func fits(_ sample: LocationSample, after anchor: LocationSample) -> Bool {
        guard distance(anchor, sample) <= max(configuration.spacing, tolerance(of: sample)),
              !climbed(from: anchor, to: sample),
              sample.timestamp.timeIntervalSince(windowStart) <= configuration.maximumDelay
        else { return false }
        let (bx, by) = offset(of: sample, from: anchor)
        for skipped in window {
            let (px, py) = offset(of: skipped, from: anchor)
            if Self.distanceToSegment(px, py, bx, by) > tolerance(of: skipped) { return false }
        }
        return true
    }

    func tolerance(of sample: LocationSample) -> Double {
        min(max(1.5 * sample.horizontalAccuracy, configuration.tolerance), configuration.maximumTolerance)
    }

    func climbed(from a: LocationSample, to b: LocationSample) -> Bool {
        guard a.hasValidAltitude, b.hasValidAltitude else { return false }
        let threshold = max(configuration.minimumClimb, a.verticalAccuracy, b.verticalAccuracy)
        return abs(b.altitude - a.altitude) >= threshold
    }

    func distance(_ a: LocationSample, _ b: LocationSample) -> Double {
        let (x, y) = offset(of: b, from: a)
        return (x * x + y * y).squareRoot()
    }

    /// Local east/north offset in metres (equirectangular, exact enough over a few hundred metres).
    private func offset(of sample: LocationSample, from origin: LocationSample) -> (Double, Double) {
        let metersPerDegree = 111_320.0
        let east = (sample.longitude - origin.longitude) * metersPerDegree * cos(origin.latitude * .pi / 180)
        let north = (sample.latitude - origin.latitude) * metersPerDegree
        return (east, north)
    }

    /// Distance from (px, py) to the segment from the origin to (bx, by).
    private static func distanceToSegment(_ px: Double, _ py: Double, _ bx: Double, _ by: Double) -> Double {
        let length2 = bx * bx + by * by
        guard length2 > 0 else { return (px * px + py * py).squareRoot() }
        let t = max(0, min(1, (px * bx + py * by) / length2))
        let dx = px - t * bx, dy = py - t * by
        return (dx * dx + dy * dy).squareRoot()
    }
}
