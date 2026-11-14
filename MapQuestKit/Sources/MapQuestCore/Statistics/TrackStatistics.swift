import Foundation

/// Figures of a stretch of track.
public struct TrackStatistics: Hashable, Sendable {
    public var fixes = 0
    /// Time covered by fixes (gaps longer than 10 s count as 10 s).
    public var recordedSeconds: TimeInterval = 0
    /// Distance travelled along the sampled path (jitter does not add up; gaps
    /// over two minutes are not bridged).
    public var distanceMeters: Double = 0
    /// Distance walked (`walkedMeters(_:)`): at walking pace only, no rides.
    public var walkedMeters: Double = 0
    public var activeDays = 0
    public var first: Date?
    public var last: Date?

    public init() {}

    /// Statistics of chronologically sorted track points.
    public static func of(_ points: [TrackPoint], calendar: Calendar, sampling: CoverageSampler.Configuration = .init()) -> TrackStatistics {
        var result = TrackStatistics()
        result.fixes = points.count
        result.first = points.first?.timestamp
        result.last = points.last?.timestamp
        var days = Set<Date>()
        for (a, b) in zip(points, points.dropFirst()) {
            result.recordedSeconds += min(Double(b.time - a.time) / 10, 10)
        }
        if !points.isEmpty { result.recordedSeconds += 1 }
        for point in points {
            days.insert(calendar.startOfDay(for: point.timestamp))
        }
        result.activeDays = days.count
        var sampler = CoverageSampler(configuration: sampling)
        var kept: [LocationSample] = []
        for point in points { kept += sampler.add(point.sample) }
        kept += sampler.finish()
        for (a, b) in zip(kept, kept.dropFirst()) where b.timestamp.timeIntervalSince(a.timestamp) <= 120 {
            result.distanceMeters += a.coordinate.distance(to: b.coordinate)
        }
        result.walkedMeters = walkedMeters(points)
        return result
    }

    /// Fixes further apart in time are not joined (seconds).
    public static let walkingGap: TimeInterval = 10
    /// Faster is not walking: running up to about 11 km/h still counts; bikes, cars and trains do not (m/s).
    public static let maximumWalkingSpeed = 3.0
    /// Slower is standing (GPS drift), not walking (m/s).
    public static let minimumWalkingSpeed = 0.5
    /// Each point of the line is the mean of this many fixes, which evens out GPS jitter.
    public static let walkingSmoothing = 5
    /// Points of the walked line are at least this far apart, or as far as the fix's accuracy (metres).
    public static let walkingStep = 5.0
    /// Fixes less accurate than this do not draw the line (metres).
    public static let walkingAccuracy = 30.0

    /// The distance walked: a line through the fixes where they are close together
    /// in time (at most `walkingGap` apart) and space (at walking pace, between
    /// `minimumWalkingSpeed` and `maximumWalkingSpeed`), each point the mean of the
    /// last `walkingSmoothing` fixes, thinned to points at least `walkingStep` – or the
    /// fix's accuracy – apart, so that standing still, GPS jumps and rides add nothing.
    public static func walkedMeters(_ points: [TrackPoint]) -> Double {
        var tracer = WalkTracer()
        for point in points { tracer.add(point) }
        return tracer.meters
    }

    /// The distance walked per day (start of day in `calendar`).
    public static func walkedMetersByDay(_ points: [TrackPoint], calendar: Calendar) -> [Date: Double] {
        var result: [Date: Double] = [:]
        var tracer = WalkTracer()
        var day: Date?
        for point in points {
            let start = calendar.startOfDay(for: point.timestamp)
            if start != day {
                if let day { result[day, default: 0] += tracer.meters }
                tracer = WalkTracer()
                day = start
            }
            tracer.add(point)
        }
        if let day { result[day, default: 0] += tracer.meters }
        return result
    }

    /// Draws the walked line fix by fix.
    struct WalkTracer {
        private(set) var meters = 0.0
        /// The last point of the line (smoothed) and when it was reached.
        private var anchor: (coordinate: GeoCoordinate, time: Int64)?
        /// The last usable fix, and the recent ones for smoothing.
        private var previous: TrackPoint?
        private var recent: [TrackPoint] = []

        mutating func add(_ point: TrackPoint) {
            guard point.hasValidPosition, point.horizontalAccuracy <= TrackStatistics.walkingAccuracy else { return }
            defer { previous = point }
            if let previous, Double(point.time - previous.time) / 10 > TrackStatistics.walkingGap {
                recent = []  // a gap: a new line
                anchor = nil
            }
            recent.append(point)
            if recent.count > TrackStatistics.walkingSmoothing { recent.removeFirst() }
            // The line starts once there are enough fixes to average (a ride must not look slow while they fill up).
            guard recent.count == TrackStatistics.walkingSmoothing else { return }
            let n = Double(recent.count)
            let smoothed = GeoCoordinate(latitude: recent.reduce(0) { $0 + $1.latitude } / n,
                                         longitude: recent.reduce(0) { $0 + $1.longitude } / n)
            guard let anchor else {
                self.anchor = (smoothed, point.time)
                return
            }
            let distance = anchor.coordinate.distance(to: smoothed)
            guard distance >= max(TrackStatistics.walkingStep, point.horizontalAccuracy) else { return }
            let speed = distance / max(Double(point.time - anchor.time) / 10, 0.1)
            if speed >= TrackStatistics.minimumWalkingSpeed && speed <= TrackStatistics.maximumWalkingSpeed {
                meters += distance
            }
            // Too fast (a ride, a GPS jump) or too slow (drift): the line goes on from here without that stretch.
            self.anchor = (smoothed, point.time)
        }
    }

    /// Sums statistics of consecutive stretches (e.g. days).
    public static func combined(_ parts: [TrackStatistics]) -> TrackStatistics {
        var result = TrackStatistics()
        for part in parts {
            result.fixes += part.fixes
            result.recordedSeconds += part.recordedSeconds
            result.distanceMeters += part.distanceMeters
            result.walkedMeters += part.walkedMeters
            result.activeDays += part.activeDays
            result.first = [result.first, part.first].compactMap { $0 }.min()
            result.last = [result.last, part.last].compactMap { $0 }.max()
        }
        return result
    }
}
