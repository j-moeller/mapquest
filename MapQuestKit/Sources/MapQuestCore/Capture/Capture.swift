import Foundation

/// A captured sight.
public struct CaptureRecord: Codable, Hashable, Sendable {
    public var sightID: String
    /// When the sight was reached: the first discovery of the area that reaches it.
    public var capturedAt: Date
    /// When the capture was noticed.
    public var recordedAt: Date
    /// Whether the capture has been celebrated (animation shown or skipped).
    public var celebrated: Bool

    public init(sightID: String, capturedAt: Date, recordedAt: Date, celebrated: Bool) {
        self.sightID = sightID
        self.capturedAt = capturedAt
        self.recordedAt = recordedAt
        self.celebrated = celebrated
    }
}

/// All captures of one data source. Captures are kept once made – rebuilding the
/// discovered area with other parameters does not take them away – unless the
/// capture rule changes (`currentVersion`): logs made under an older rule are
/// discarded and the captures checked again.
public struct CaptureLog: Codable, Equatable, Sendable {
    /// 1: any layer within the sight's radius. 2: the radius layer must cover the
    /// sight (within `Sight.captureTolerance`).
    public static let currentVersion = 2
    public var version = CaptureLog.currentVersion
    public var records: [String: CaptureRecord] = [:]
    /// Sights whose unlocked entry has been opened (the others are marked new).
    public var readEntries: Set<String> = []

    public init(records: [String: CaptureRecord] = [:]) {
        self.records = records
    }

    enum CodingKeys: String, CodingKey {
        case version, records, readEntries
    }

    /// Logs written before entries existed have no `readEntries`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        records = try container.decode([String: CaptureRecord].self, forKey: .records)
        readEntries = try container.decodeIfPresent(Set<String>.self, forKey: .readEntries) ?? []
    }

    /// A captured sight whose entry has not been opened yet.
    public func hasUnreadEntry(_ sightID: String) -> Bool {
        isCaptured(sightID) && !readEntries.contains(sightID)
    }

    public func isCaptured(_ sightID: String) -> Bool { records[sightID] != nil }

    /// Captures waiting for their celebration, oldest first.
    public var uncelebrated: [CaptureRecord] {
        records.values.filter { !$0.celebrated }.sorted { ($0.recordedAt, $0.sightID) < ($1.recordedAt, $1.sightID) }
    }

    public mutating func markCelebrated(_ sightIDs: [String]) {
        for id in sightIDs { records[id]?.celebrated = true }
    }
}

/// The capture rule: a sight is captured when you have been there – when the
/// area discovered around your positions (the radius layer, circles around
/// them; not the line of sight) covers the sight's position, or comes within
/// `Sight.captureTolerance` of it for large open areas.
public enum SightCapture {
    /// When the discovered area first reached `sight` (the earliest first-discovery
    /// date of the pieces covering it), or `nil` if it does not.
    public static func captureDate(of sight: Sight, in snapshots: [DiscoveredAreaSnapshot]) -> Date? {
        let point = sight.point
        let radius = sight.captureTolerance / WebMercator.metersPerUnit(atWorldY: Double(point.y))
        let r = Int64(radius.rounded(.up)) + 1
        let rect = WorldRect(minX: point.x - r, minY: point.y - r, maxX: point.x + r, maxY: point.y + r)
        var earliest: Date?
        for snapshot in snapshots {
            for piece in snapshot.pieces(intersecting: rect) {
                let polygon = piece.polygon
                guard polygon.contains(point) || polygon.distanceToBoundary(point) <= radius else { continue }
                if earliest.map({ piece.firstDiscovered < $0 }) ?? true {
                    earliest = piece.firstDiscovered
                }
            }
        }
        return earliest
    }

    /// Adds the sights the discovered area reaches now and that are not captured
    /// yet. `celebrate`: whether the new captures should be celebrated (they are
    /// marked as celebrated otherwise, e.g. for view-only data sources).
    /// Returns the new records.
    @discardableResult
    public static func update(
        _ log: inout CaptureLog, sights: [Sight], snapshots: [DiscoveredAreaSnapshot], now: Date = Date(), celebrate: Bool = true
    ) -> [CaptureRecord] {
        var added: [CaptureRecord] = []
        for sight in sights where !log.isCaptured(sight.id) {
            guard let date = captureDate(of: sight, in: snapshots) else { continue }
            let record = CaptureRecord(sightID: sight.id, capturedAt: date, recordedAt: now, celebrated: !celebrate)
            log.records[sight.id] = record
            added.append(record)
        }
        return added
    }
}

/// Where a data source's captures are kept.
public protocol CaptureStore: Sendable {
    func load() throws -> CaptureLog
    func save(_ log: CaptureLog) throws
    func delete() throws
}

/// A capture log as a JSON file (one per data source).
public struct FileCaptureStore: CaptureStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The file for a data source in `directory` (the ID made file-name safe).
    public init(directory: URL, sourceID: String) {
        let safe = sourceID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        self.init(url: directory.appendingPathComponent("\(safe).json"))
    }

    /// An empty log if there is no file yet, or if it was made under an older capture rule.
    public func load() throws -> CaptureLog {
        guard FileManager.default.fileExists(atPath: url.path) else { return CaptureLog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let log = try decoder.decode(CaptureLog.self, from: Data(contentsOf: url))
        return log.version < CaptureLog.currentVersion ? CaptureLog() : log
    }

    public func save(_ log: CaptureLog) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(log).write(to: url, options: .atomic)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
