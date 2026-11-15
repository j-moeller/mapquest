import Foundation

/// Everything a data source's state is made of, as one ZIP file – for backups and
/// moving to another device. The discovered area is not in it: it is a cache,
/// rebuilt from the positions after an import.
///
///     manifest.json                 what is inside (format, version, counts, photos)
///     README.txt                    this layout, for people
///     positions/samples.json        the key positions the discovered area is computed from
///     positions/track/<day>.json    every recorded position (about one per second), one file per UTC day
///     captures/log.json             sights near, discovered and captured, stations, photo records
///     photos/<sha256>.jpg           the photos, named by the SHA-256 of their content (like git's objects)
///     settings.json                 the app's settings (opaque to this format)
///
/// Times of positions are seconds since 1970-01-01 UTC; coordinates WGS84 degrees;
/// altitudes and accuracies metres (accuracy −1: invalid). Track values keep the
/// track's own precision (0.1 s, 10⁻⁶ degree, 0.1 m), so an import restores them
/// exactly; key positions keep their IDs and their times to the microsecond.
public enum DataArchive {
    public static let format = "mapquest-data"
    public static let version = 1

    public struct Manifest: Codable, Equatable, Sendable {
        public struct Source: Codable, Equatable, Sendable {
            public var id: String
            public var name: String

            public init(id: String, name: String) {
                self.id = id
                self.name = name
            }
        }

        public struct Photo: Codable, Equatable, Sendable {
            /// Path in the archive (`photos/<sha256>.jpg`).
            public var file: String
            /// The app's own file name, referenced by the capture log.
            public var fileName: String
            public var sha256: String
        }

        public var format: String
        public var version: Int
        public var exportedAt: Date
        /// The app that wrote it ("MapQuest 1.0 (42)").
        public var app: String?
        public var source: Source
        public var samples: Int
        public var trackPoints: Int
        /// The days of the track (`positions/track/<day>.json`), oldest first.
        public var trackDays: [String]
        public var sightsNearby: Int
        public var sightsDiscovered: Int
        public var sightsCaptured: Int
        public var stationsCollected: Int
        public var photos: [Photo]
        /// Photos the capture log names whose file was missing.
        public var missingPhotos: Int
        public var hasCaptureLog: Bool
        public var hasSettings: Bool
    }

    /// What to put into an archive.
    public struct Export: Sendable {
        public var source: Manifest.Source
        public var app: String?
        public var samples: [LocationSample]
        public var track: [TrackPoint]
        public var captureLog: CaptureLog?
        /// Where the capture log's photos are.
        public var photoDirectory: URL?
        public var settings: Data?

        public init(source: Manifest.Source, app: String? = nil, samples: [LocationSample], track: [TrackPoint],
                    captureLog: CaptureLog? = nil, photoDirectory: URL? = nil, settings: Data? = nil) {
            self.source = source
            self.app = app
            self.samples = samples
            self.track = track
            self.captureLog = captureLog
            self.photoDirectory = photoDirectory
            self.settings = settings
        }
    }

    public enum ArchiveError: Error, Equatable, LocalizedError {
        case notAMapQuestArchive
        case newerVersion(Int)
        case damagedPhoto(String)
        case unexpectedTrackColumns(String)

        public var errorDescription: String? {
            switch self {
            case .notAMapQuestArchive: return "This is not a MapQuest export." // not localized: the app shows its own text
            case .newerVersion(let version): return "This export (format \(version)) is from a newer version of the app." // not localized
            case .damagedPhoto(let file): return "Damaged photo in the export: \(file)" // not localized
            case .unexpectedTrackColumns(let file): return "Unexpected columns in \(file)" // not localized
            }
        }
    }

    static let trackColumns = ["time", "latitude", "longitude", "altitude", "horizontalAccuracy", "verticalAccuracy"]

    // MARK: Writing

    /// Writes an archive; `progress` gets the share done (0…1).
    @discardableResult
    public static func write(_ export: Export, to url: URL, now: Date = Date(), progress: ((Double) -> Void)? = nil) throws -> Manifest {
        let zip = try ZipWriter(url: url)
        let days = Dictionary(grouping: export.track) { $0.time / 864_000 }  // deciseconds per day
        let dayKeys = days.keys.sorted()
        let photoTasks = export.captureLog?.album ?? []
        let steps = Double(2 + dayKeys.count + photoTasks.count)
        var done = 0.0
        func step() {
            done += 1
            progress?(min(1, done / steps))
        }

        let sampleEncoder = JSONEncoder()
        sampleEncoder.dateEncodingStrategy = .secondsSince1970
        sampleEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let samples = export.samples.sorted { $0.timestamp < $1.timestamp }
        try zip.add("positions/samples.json", data: sampleEncoder.encode(samples), modified: now)
        step()

        var dayNames: [String] = []
        for key in dayKeys {
            let points = days[key]!.sorted { $0.time < $1.time }
            let name = dayName(key)
            dayNames.append(name)
            try zip.add("positions/track/\(name).json", data: trackJSON(points, day: name), modified: now)
            step()
        }

        var photos: [Manifest.Photo] = []
        var stored = Set<String>()
        var missing = 0
        for photo in photoTasks {
            defer { step() }
            guard let directory = export.photoDirectory,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(photo.fileName)) else {
                missing += 1
                continue
            }
            let hash = SHA256Digest.hex(data)
            let ext = (photo.fileName as NSString).pathExtension.lowercased()
            let file = "photos/\(hash).\(ext.isEmpty ? "jpg" : ext)"
            if stored.insert(file).inserted {
                try zip.add(file, data: data, compress: false, modified: photo.takenAt)
            }
            photos.append(Manifest.Photo(file: file, fileName: photo.fileName, sha256: hash))
        }

        let isoEncoder = JSONEncoder()
        isoEncoder.dateEncodingStrategy = .iso8601
        isoEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let log = export.captureLog {
            try zip.add("captures/log.json", data: isoEncoder.encode(log), modified: now)
        }
        if let settings = export.settings {
            try zip.add("settings.json", data: settings, modified: now)
        }
        let log = export.captureLog
        let manifest = Manifest(
            format: format, version: version, exportedAt: now, app: export.app, source: export.source,
            samples: samples.count, trackPoints: export.track.count, trackDays: dayNames,
            sightsNearby: log.map { log in log.nearby.keys.filter { !log.isDiscovered($0) }.count } ?? 0,
            sightsDiscovered: log?.records.count ?? 0, sightsCaptured: log?.photos.count ?? 0,
            stationsCollected: log?.stations.count ?? 0, photos: photos, missingPhotos: missing,
            hasCaptureLog: log != nil, hasSettings: export.settings != nil
        )
        try zip.add("README.txt", data: Data(readme.utf8), modified: now)
        try zip.add("manifest.json", data: isoEncoder.encode(manifest), modified: now)
        step()
        try zip.finish()
        return manifest
    }

    /// One day of the track: a row per position, values at the track's precision.
    static func trackJSON(_ points: [TrackPoint], day: String) -> Data {
        var text = "{\"date\":\"\(day)\",\"columns\":["
        text += trackColumns.map { "\"\($0)\"" }.joined(separator: ",")
        text += "],\"points\":[\n"
        text += points.map { point in
            "[" + [
                fixed(point.time, scale: 10, digits: 1),
                fixed(Int64(point.latitudeE6), scale: 1_000_000, digits: 6),
                fixed(Int64(point.longitudeE6), scale: 1_000_000, digits: 6),
                fixed(Int64(point.altitudeDM), scale: 10, digits: 1),
                point.horizontalAccuracyDM < 0 ? "-1" : fixed(Int64(point.horizontalAccuracyDM), scale: 10, digits: 1),
                point.verticalAccuracyDM < 0 ? "-1" : fixed(Int64(point.verticalAccuracyDM), scale: 10, digits: 1),
            ].joined(separator: ",") + "]"
        }.joined(separator: ",\n")
        text += "\n]}\n"
        return Data(text.utf8)
    }

    /// An integer with an implied decimal scale, exactly ("52.520008").
    static func fixed(_ value: Int64, scale: Int64, digits: Int) -> String {
        let magnitude = value.magnitude
        let whole = magnitude / UInt64(scale), fraction = String(magnitude % UInt64(scale))
        return (value < 0 ? "-" : "") + String(whole) + "." + String(repeating: "0", count: digits - fraction.count) + fraction
    }

    /// "2026-11-14" for a day number since 1970 (UTC).
    static func dayName(_ day: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: Double(day) * 86_400))
    }

    static let readme = """
    MapQuest export

    Everything one data source of MapQuest is made of; the app imports it again
    (Menu › Export and import). The discovered area is not included: the app
    recomputes it from the positions.

    manifest.json               what is inside: format, version, counts, the photos
    positions/samples.json      the key positions the discovered area is computed from
    positions/track/<day>.json  every recorded position, one file per UTC day; rows are
                                [time, latitude, longitude, altitude, horizontalAccuracy, verticalAccuracy]
    captures/log.json           sights near, discovered and captured, stations collected, photo records
    photos/<sha256>.jpg         the photos, named by the SHA-256 of their content
    settings.json               the app's settings

    Times of positions are seconds since 1970-01-01 UTC, coordinates WGS84 degrees,
    altitudes and accuracies metres (an accuracy of -1 means invalid).

    """ // not localized: part of the file format

    // MARK: Reading

    /// Reads an archive: the manifest at once, the rest on request.
    public final class Reader: @unchecked Sendable {
        public let manifest: Manifest
        private let zip: ZipReader

        public init(url: URL) throws {
            let zip: ZipReader
            do {
                zip = try ZipReader(url: url)
            } catch ZipError.notAZipArchive {
                throw ArchiveError.notAMapQuestArchive
            }
            guard zip.contains("manifest.json") else { throw ArchiveError.notAMapQuestArchive }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(Manifest.self, from: zip.data("manifest.json"))
            guard manifest.format == DataArchive.format else { throw ArchiveError.notAMapQuestArchive }
            guard manifest.version <= DataArchive.version else { throw ArchiveError.newerVersion(manifest.version) }
            self.manifest = manifest
            self.zip = zip
        }

        public func samples() throws -> [LocationSample] {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode([LocationSample].self, from: zip.data("positions/samples.json"))
        }

        /// The positions of one day of the track (`manifest.trackDays`).
        public func trackPoints(day: String) throws -> [TrackPoint] {
            struct Day: Decodable {
                var columns: [String]
                var points: [[Double]]
            }
            let file = "positions/track/\(day).json"
            let decoded = try JSONDecoder().decode(Day.self, from: zip.data(file))
            guard decoded.columns == DataArchive.trackColumns else { throw ArchiveError.unexpectedTrackColumns(file) }
            return decoded.points.compactMap { row in
                guard row.count == 6 else { return nil }
                func scaled(_ value: Double, _ scale: Double) -> Int32 { Int32((value * scale).rounded()) }
                return TrackPoint(
                    time: Int64((row[0] * 10).rounded()), latitudeE6: scaled(row[1], 1e6), longitudeE6: scaled(row[2], 1e6),
                    altitudeDM: scaled(row[3], 10),
                    horizontalAccuracyDM: row[4] < 0 ? -1 : scaled(row[4], 10),
                    verticalAccuracyDM: row[5] < 0 ? -1 : scaled(row[5], 10)
                )
            }.sorted { $0.time < $1.time }
        }

        public func captureLog() throws -> CaptureLog? {
            guard zip.contains("captures/log.json") else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CaptureLog.self, from: zip.data("captures/log.json"))
        }

        public func settings() throws -> Data? {
            zip.contains("settings.json") ? try zip.data("settings.json") : nil
        }

        /// Writes the photos under their own file names into `directory`, each checked
        /// against its hash. Returns how many were written.
        @discardableResult
        public func restorePhotos(to directory: URL, progress: ((Int, Int) -> Void)? = nil) throws -> Int {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var written = 0
            for (index, photo) in manifest.photos.enumerated() {
                let data = try zip.data(photo.file)
                guard SHA256Digest.hex(data) == photo.sha256 else { throw ArchiveError.damagedPhoto(photo.file) }
                // Only a plain file name: nothing outside the directory.
                let name = (photo.fileName as NSString).lastPathComponent
                guard !name.isEmpty, name != "..", name != "." else { continue }
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                written += 1
                progress?(index + 1, manifest.photos.count)
            }
            return written
        }
    }

    // MARK: Restoring

    /// Replaces the positions of a store – key positions and track – with the
    /// archive's, and removes its discovered area (rebuild it from the positions).
    public static func restorePositions(
        from reader: Reader, into store: any MapQuestDataStore, progress: ((Double) -> Void)? = nil
    ) async throws {
        try await store.removeAllSamples()
        try await store.removeAllTrack()
        for layer in try await store.layers() {
            try await store.removeAllPieces(layer: layer)
        }
        let samples = try reader.samples()
        for start in stride(from: 0, to: samples.count, by: 500) {
            try await store.addSamples(Array(samples[start..<min(start + 500, samples.count)]))
        }
        let days = reader.manifest.trackDays
        for (index, day) in days.enumerated() {
            let points = try reader.trackPoints(day: day)
            // Segments of ten minutes at one position per second, as recorded.
            let segments = stride(from: 0, to: points.count, by: 600).map { start in
                TrackSegment(points: Array(points[start..<min(start + 600, points.count)]))
            }
            if !segments.isEmpty { try await store.putTrackSegments(segments) }
            progress?(Double(index + 1) / Double(max(days.count, 1)))
        }
    }
}
