import Foundation

/// Figures of a stretch of track.
public struct TrackStatistics: Hashable, Sendable {
    public var fixes = 0
    /// Time covered by fixes (gaps longer than 10 s count as 10 s).
    public var recordedSeconds: TimeInterval = 0
    /// Distance travelled along the sampled path (jitter does not add up; gaps
    /// over two minutes are not bridged).
    public var distanceMeters: Double = 0
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
        return result
    }

    /// Sums statistics of consecutive stretches (e.g. days).
    public static func combined(_ parts: [TrackStatistics]) -> TrackStatistics {
        var result = TrackStatistics()
        for part in parts {
            result.fixes += part.fixes
            result.recordedSeconds += part.recordedSeconds
            result.distanceMeters += part.distanceMeters
            result.activeDays += part.activeDays
            result.first = [result.first, part.first].compactMap { $0 }.min()
            result.last = [result.last, part.last].compactMap { $0 }.max()
        }
        return result
    }
}
