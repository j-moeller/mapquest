import Foundation

/// Appends fixes to the track, about one per second, in segments.
///
/// Points are buffered in the open segment, which is written (replaced) every
/// `flushPoints` points or `flushInterval` seconds, so at most that much is lost
/// if the app is killed. A segment is closed after `maximumSegmentPoints` points
/// or a gap of `maximumGap` seconds. Writes reach the store in order.
public actor TrackWriter {
    public struct Configuration: Hashable, Sendable {
        /// Fixes closer in time to the previous stored fix are dropped (seconds).
        public var minimumInterval: TimeInterval
        public var maximumSegmentPoints: Int
        /// A longer pause starts a new segment (seconds).
        public var maximumGap: TimeInterval
        public var flushPoints: Int
        /// Seconds of track time after which the open segment is written.
        public var flushInterval: TimeInterval

        public init(
            minimumInterval: TimeInterval = 0.9,
            maximumSegmentPoints: Int = 600,
            maximumGap: TimeInterval = 120,
            flushPoints: Int = 30,
            flushInterval: TimeInterval = 30
        ) {
            self.minimumInterval = minimumInterval
            self.maximumSegmentPoints = maximumSegmentPoints
            self.maximumGap = maximumGap
            self.flushPoints = flushPoints
            self.flushInterval = flushInterval
        }
    }

    public nonisolated let store: any TrackStore
    public nonisolated let configuration: Configuration
    private var openID = UUID()
    private var open: [TrackPoint] = []
    private var unflushed = 0
    private var lastFlushTime: Int64?
    private var lastWrite: Task<Void, Error>?

    public init(store: any TrackStore, configuration: Configuration = Configuration()) {
        self.store = store
        self.configuration = configuration
    }

    /// The fixes not yet written.
    public var pendingPointCount: Int { unflushed }

    /// Appends a fix; returns whether it was kept (invalid or too frequent fixes are not).
    @discardableResult
    public func append(_ point: TrackPoint) async throws -> Bool {
        guard point.hasValidPosition else { return false }
        if let last = open.last {
            let gap = Double(point.time - last.time) / 10
            guard gap >= configuration.minimumInterval else { return false }
            if gap > configuration.maximumGap || open.count >= configuration.maximumSegmentPoints {
                try await closeSegment()
            }
        }
        open.append(point)
        unflushed += 1
        let since = Double(point.time - (lastFlushTime ?? point.time)) / 10
        if lastFlushTime == nil { lastFlushTime = point.time }
        if unflushed >= configuration.flushPoints || since >= configuration.flushInterval {
            try await flush()
        }
        return true
    }

    /// Writes the open segment (e.g. when the app goes to the background).
    public func flush() async throws {
        guard unflushed > 0, !open.isEmpty else { return }
        let segment = TrackSegment(id: openID, points: open)
        unflushed = 0
        lastFlushTime = open.last?.time
        try await write(segment)
    }

    private func closeSegment() async throws {
        try await flush()
        open = []
        openID = UUID()
        lastFlushTime = nil
    }

    /// Writes after all earlier writes (the task is created before any suspension).
    private func write(_ segment: TrackSegment) async throws {
        let previous = lastWrite
        let store = self.store
        let task = Task {
            _ = await previous?.result
            try await store.putTrackSegments([segment])
        }
        lastWrite = task
        try await task.value
    }
}
