import Foundation

/// A visit to a place: a sight discovered (its entry unlocked; photographing it
/// captures it, `PhotoCapture`) or a station collected.
public struct CaptureRecord: Codable, Hashable, Sendable {
    /// The sight's or station's ID.
    public var sightID: String
    /// When the place was reached: the first discovery of the area that reaches it.
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

/// A captured sight: photographed there and the photo saved.
public struct PhotoCapture: Codable, Hashable, Sendable {
    public var sightID: String
    /// When the sight was first photographed: it counts as captured from then on.
    public var capturedAt: Date
    /// When the photo kept now was taken (a new photo replaces the old one).
    public var takenAt: Date
    /// Where it was taken.
    public var latitude: Double?
    public var longitude: Double?
    /// The photo's file in the data source's photo folder.
    public var fileName: String

    public init(sightID: String, capturedAt: Date, takenAt: Date, latitude: Double? = nil, longitude: Double? = nil, fileName: String) {
        self.sightID = sightID
        self.capturedAt = capturedAt
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
        self.fileName = fileName
    }
}

/// Everything one data source has found: sights discovered by going there
/// (`records`: their entries unlock), sights captured by photographing them
/// there (`photos`), and stations collected by going there (`stations`).
/// Visits are kept once made – rebuilding the discovered area with other
/// parameters does not take them away – unless the rule changes
/// (`currentVersion`): logs made under an older rule are discarded and the
/// visits checked again. Photos are never discarded with a rule.
public struct CaptureLog: Codable, Equatable, Sendable {
    /// 1: any layer within the sight's radius. 2: the radius layer must cover the
    /// sight (within `Sight.captureTolerance`).
    public static let currentVersion = 2
    public var version = CaptureLog.currentVersion
    /// Discovered sights.
    public var records: [String: CaptureRecord] = [:]
    /// Captured (photographed) sights.
    public var photos: [String: PhotoCapture] = [:]
    /// Collected stations.
    public var stations: [String: CaptureRecord] = [:]
    /// Sights whose unlocked entry has been opened (the others are marked new).
    public var readEntries: Set<String> = []

    public init(records: [String: CaptureRecord] = [:], photos: [String: PhotoCapture] = [:], stations: [String: CaptureRecord] = [:]) {
        self.records = records
        self.photos = photos
        self.stations = stations
    }

    enum CodingKeys: String, CodingKey {
        case version, records, photos, stations, readEntries
    }

    /// Older logs have no `readEntries`, `photos` or `stations`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        records = try container.decode([String: CaptureRecord].self, forKey: .records)
        photos = try container.decodeIfPresent([String: PhotoCapture].self, forKey: .photos) ?? [:]
        stations = try container.decodeIfPresent([String: CaptureRecord].self, forKey: .stations) ?? [:]
        readEntries = try container.decodeIfPresent(Set<String>.self, forKey: .readEntries) ?? []
    }

    /// A discovered sight whose entry has not been opened yet.
    public func hasUnreadEntry(_ sightID: String) -> Bool {
        isDiscovered(sightID) && !readEntries.contains(sightID)
    }

    /// Whether you have been at the sight (its entry is unlocked).
    public func isDiscovered(_ sightID: String) -> Bool { records[sightID] != nil }

    /// Whether the sight has been photographed there (captured).
    public func isCaptured(_ sightID: String) -> Bool { photos[sightID] != nil }

    /// When each captured sight and collected station was captured – what achievements count.
    public var captureDates: [String: Date] {
        var dates = stations.mapValues(\.capturedAt)
        for (id, photo) in photos { dates[id] = photo.capturedAt }
        return dates
    }

    /// Captures waiting for their celebration, oldest first.
    public var uncelebrated: [CaptureRecord] {
        records.values.filter { !$0.celebrated }.sorted { ($0.recordedAt, $0.sightID) < ($1.recordedAt, $1.sightID) }
    }

    public mutating func markCelebrated(_ sightIDs: [String]) {
        for id in sightIDs { records[id]?.celebrated = true }
    }
}

/// The visiting rule: a place is reached when you have been there – when the
/// area discovered around your positions (the radius layer, circles around
/// them; not the line of sight) covers its position, or comes within its
/// tolerance of it for large places. Reaching a sight discovers it (photographing
/// it then captures it); reaching a station collects it.
public enum PlaceCapture {
    /// When the discovered area first reached the point (the earliest first-discovery
    /// date of the pieces covering it, or within `tolerance` metres), or `nil`.
    public static func captureDate(at point: WorldPoint, tolerance: Double, in snapshots: [DiscoveredAreaSnapshot]) -> Date? {
        let radius = tolerance / WebMercator.metersPerUnit(atWorldY: Double(point.y))
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
}

/// Discovering sights by going there (see `PlaceCapture`).
public enum SightCapture {
    /// When the discovered area first reached `sight`, or `nil` if it does not.
    public static func captureDate(of sight: Sight, in snapshots: [DiscoveredAreaSnapshot]) -> Date? {
        PlaceCapture.captureDate(at: sight.point, tolerance: sight.captureTolerance, in: snapshots)
    }

    /// Adds the sights the discovered area reaches now and that are not discovered
    /// yet. `celebrate`: whether the discoveries should be celebrated (they are
    /// marked as celebrated otherwise, e.g. for view-only data sources).
    /// Returns the new records.
    @discardableResult
    public static func update(
        _ log: inout CaptureLog, sights: [Sight], snapshots: [DiscoveredAreaSnapshot], now: Date = Date(), celebrate: Bool = true
    ) -> [CaptureRecord] {
        var added: [CaptureRecord] = []
        for sight in sights where !log.isDiscovered(sight.id) {
            guard let date = captureDate(of: sight, in: snapshots) else { continue }
            let record = CaptureRecord(sightID: sight.id, capturedAt: date, recordedAt: now, celebrated: !celebrate)
            log.records[sight.id] = record
            added.append(record)
        }
        return added
    }
}

/// Collecting stations by going there (see `PlaceCapture`): no photo needed.
public enum StationCapture {
    /// Adds the stations the discovered area reaches now and that are not collected
    /// yet. Returns the new records (marked celebrated: the app announces them at once).
    @discardableResult
    public static func update(
        _ log: inout CaptureLog, stations: [Station], snapshots: [DiscoveredAreaSnapshot], now: Date = Date()
    ) -> [CaptureRecord] {
        var added: [CaptureRecord] = []
        for station in stations where log.stations[station.id] == nil {
            guard let date = PlaceCapture.captureDate(at: station.point, tolerance: station.captureTolerance, in: snapshots) else { continue }
            let record = CaptureRecord(sightID: station.id, capturedAt: date, recordedAt: now, celebrated: true)
            log.stations[station.id] = record
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
