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

/// A captured sight: photographed and the photo saved. The sight's photos are
/// all kept (`CaptureLog.album`); this record holds the capture and its latest photo.
public struct PhotoCapture: Codable, Hashable, Sendable {
    public var sightID: String
    /// When the sight was first photographed: it counts as captured from then on.
    public var capturedAt: Date
    /// When its latest photo was taken.
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

/// A photo you took of a sight. Every photo is kept: the sight's gallery, and all
/// of them together in the menu's Photos.
public struct TakenPhoto: Codable, Hashable, Identifiable, Sendable {
    public var sightID: String
    public var takenAt: Date
    /// Where it was taken.
    public var latitude: Double?
    public var longitude: Double?
    /// The photo's file in the data source's photo folder (unique per photo).
    public var fileName: String

    public var id: String { fileName }

    public init(sightID: String, takenAt: Date, latitude: Double? = nil, longitude: Double? = nil, fileName: String) {
        self.sightID = sightID
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
        self.fileName = fileName
    }
}

/// Everything one data source has found: sights you came near (`nearby`: a
/// question mark on the map), sights discovered by going there (`records`: their
/// entries unlock), sights captured by photographing them (`photos`), and
/// stations collected by going there (`stations`).
/// Visits are kept once made – rebuilding the discovered area with other
/// parameters does not take them away – unless the rule changes
/// (`currentVersion`): logs made under an older rule are discarded and the
/// visits checked again. Photos are never discarded with a rule.
public struct CaptureLog: Codable, Equatable, Sendable {
    /// 1: any layer within the sight's radius. 2: the radius layer must cover the
    /// sight (within `Sight.captureTolerance`).
    public static let currentVersion = 2
    public var version = CaptureLog.currentVersion
    /// Sights you came near (within `SightCapture.nearbyDistance`), and when – a
    /// question mark on the map until they are discovered.
    public var nearby: [String: Date] = [:]
    /// Discovered sights.
    public var records: [String: CaptureRecord] = [:]
    /// Captured (photographed) sights.
    public var photos: [String: PhotoCapture] = [:]
    /// Every photo taken, oldest first (a sight's gallery: `photos(of:)`).
    public var album: [TakenPhoto] = []
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
        case version, nearby, records, photos, album, stations, readEntries
    }

    /// Older logs have no `nearby`, `readEntries`, `photos`, `album` or `stations`; without an
    /// album (one photo per sight, replaced by a new one), each sight's photo starts it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        nearby = try container.decodeIfPresent([String: Date].self, forKey: .nearby) ?? [:]
        records = try container.decode([String: CaptureRecord].self, forKey: .records)
        photos = try container.decodeIfPresent([String: PhotoCapture].self, forKey: .photos) ?? [:]
        album = try container.decodeIfPresent([TakenPhoto].self, forKey: .album)
            ?? photos.values.map {
                TakenPhoto(sightID: $0.sightID, takenAt: $0.takenAt, latitude: $0.latitude, longitude: $0.longitude, fileName: $0.fileName)
            }.sorted { ($0.takenAt, $0.fileName) < ($1.takenAt, $1.fileName) }
        stations = try container.decodeIfPresent([String: CaptureRecord].self, forKey: .stations) ?? [:]
        readEntries = try container.decodeIfPresent(Set<String>.self, forKey: .readEntries) ?? []
    }

    /// A sight's photos, newest first.
    public func photos(of sightID: String) -> [TakenPhoto] {
        album.filter { $0.sightID == sightID }.sorted { $0.takenAt > $1.takenAt }
    }

    /// Keeps a new photo; the first one of a sight captures it. Returns whether it did.
    @discardableResult
    public mutating func addPhoto(_ photo: TakenPhoto) -> Bool {
        album.append(photo)
        let first = photos[photo.sightID] == nil
        photos[photo.sightID] = PhotoCapture(
            sightID: photo.sightID, capturedAt: photos[photo.sightID]?.capturedAt ?? photo.takenAt, takenAt: photo.takenAt,
            latitude: photo.latitude, longitude: photo.longitude, fileName: photo.fileName
        )
        return first
    }

    /// Removes a photo from the album. The sight stays captured (a capture is kept
    /// once made); its record then shows its latest remaining photo.
    public mutating func removePhoto(_ photo: TakenPhoto) {
        album.removeAll { $0.fileName == photo.fileName }
        guard var capture = photos[photo.sightID], capture.fileName == photo.fileName,
              let latest = photos(of: photo.sightID).first else { return }
        capture.takenAt = latest.takenAt
        capture.latitude = latest.latitude
        capture.longitude = latest.longitude
        capture.fileName = latest.fileName
        photos[photo.sightID] = capture
    }

    /// A discovered sight whose entry has not been opened yet.
    public func hasUnreadEntry(_ sightID: String) -> Bool {
        isDiscovered(sightID) && !readEntries.contains(sightID)
    }

    /// Whether you have been at the sight (its entry is unlocked).
    public func isDiscovered(_ sightID: String) -> Bool { records[sightID] != nil }

    /// Whether you came near the sight but have not discovered it yet (a question mark).
    public func isNearby(_ sightID: String) -> Bool { nearby[sightID] != nil && !isDiscovered(sightID) }

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

    /// Sights merged into others (`SightLibrary.aliases`: the same place in two
    /// packages): what was discovered or captured under the merged ID counts for the
    /// one it was merged into, where that has none of its own. The merged ID keeps its
    /// own (the package may be used alone again). Returns whether anything changed.
    @discardableResult
    public mutating func adoptAliases(_ aliases: [String: String]) -> Bool {
        var changed = false
        for (alias, target) in aliases.sorted(by: { $0.key < $1.key }) where alias != target {
            if let record = records[alias], records[target] == nil {
                var adopted = record
                adopted.sightID = target
                adopted.celebrated = true
                records[target] = adopted
                changed = true
            }
            if let photo = photos[alias], photos[target] == nil {
                var adopted = photo
                adopted.sightID = target
                photos[target] = adopted
                changed = true
            }
            if let date = nearby[alias], nearby[target] == nil, records[target] == nil {
                nearby[target] = date
                changed = true
            }
            if readEntries.contains(alias), readEntries.insert(target).inserted {
                changed = true
            }
        }
        return changed
    }
}

/// The visiting rule: a place is reached when you have been there – when the
/// area discovered around your positions (the radius layer, circles around
/// them; not the line of sight) covers its position, or comes within its
/// tolerance of it for large places. Reaching a sight discovers it (photographing
/// it then captures it – from where you can see it, `LineOfSightView`); reaching
/// a station collects it.
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

    /// Whether an area (e.g. what one position sees) covers the point or comes within `tolerance` metres.
    public static func reaches(_ point: WorldPoint, tolerance: Double, in polygons: [WorldPolygon]) -> Bool {
        let radius = tolerance / WebMercator.metersPerUnit(atWorldY: Double(point.y))
        return polygons.contains { $0.contains(point) || $0.distanceToBoundary(point) <= radius }
    }
}

/// What could be seen from one position: the area the line-of-sight model revealed
/// there (visible ground and the footprints of the buildings seen).
public struct LineOfSightView: Sendable {
    public var sample: LocationSample
    public var revealed: [WorldPolygon]

    public init(sample: LocationSample, revealed: [WorldPolygon]) {
        self.sample = sample
        self.revealed = revealed
    }

    /// Whether the sight is in view from there.
    public func shows(_ sight: Sight) -> Bool {
        PlaceCapture.reaches(sight.point, tolerance: sight.captureTolerance, in: revealed)
    }
}

/// Discovering sights by going there (see `PlaceCapture`); before that, coming near
/// them marks them with a question mark.
public enum SightCapture {
    /// How close (metres) your positions must come for a sight to be marked as nearby.
    public static let nearbyDistance: Double = 300

    /// How far from a sight the radius layer – circles of `circleRadius` around your
    /// positions – may end for the sight to be nearby.
    public static func nearbyTolerance(circleRadius: Double) -> Double {
        max(0, nearbyDistance - circleRadius)
    }

    /// Marks the sights the area comes within `tolerance` metres of as nearby (when
    /// first), unless they are discovered or marked already. Places of remembrance
    /// are not part of the game. Returns the sights marked.
    @discardableResult
    public static func updateNearby(
        _ log: inout CaptureLog, sights: [Sight], snapshots: [DiscoveredAreaSnapshot], tolerance: Double
    ) -> [String] {
        var marked: [String] = []
        for sight in sights where !sight.isPlaceOfRemembrance && log.nearby[sight.id] == nil && !log.isDiscovered(sight.id) {
            guard let date = PlaceCapture.captureDate(
                at: sight.point, tolerance: max(tolerance, sight.captureTolerance), in: snapshots
            ) else { continue }
            log.nearby[sight.id] = date
            marked.append(sight.id)
        }
        return marked
    }

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

    /// Undoes discoveries the area does not reach, except of sights already captured
    /// (photographed): for going back from a wider rule (the line of sight counted
    /// for a while). Returns the sights no longer discovered.
    @discardableResult
    public static func forgetUnreached(
        _ log: inout CaptureLog, sights: [Sight], snapshots: [DiscoveredAreaSnapshot]
    ) -> [String] {
        var forgotten: [String] = []
        for sight in sights where log.isDiscovered(sight.id) && !log.isCaptured(sight.id) {
            guard captureDate(of: sight, in: snapshots) == nil else { continue }
            log.records[sight.id] = nil
            forgotten.append(sight.id)
        }
        return forgotten
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
