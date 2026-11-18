import Foundation

/// A sight package: sights with their entries and facts, the chronicles that date
/// them, achievements, places of remembrance with walks, and transit stations –
/// everything the capture game knows about a place, as one JSON document
/// (docs/09-sight-packages.md). Packages compose: one may `include` others (the
/// Berlin package includes Berlin's churches), and several may describe the same
/// sight – the same ID is the same place (`SightLibrary` resolves them).
public struct SightPackage: Codable, Hashable, Identifiable, Sendable {
    /// Where a package's sights are: the app groups and follows by region.
    public struct Region: Codable, Hashable, Sendable {
        public var id: String
        public var name: LocalizedText
        public var bounds: Bounds?

        public init(id: String, name: LocalizedText, bounds: Bounds? = nil) {
            self.id = id
            self.name = name
            self.bounds = bounds
        }
    }

    /// A latitude/longitude box.
    public struct Bounds: Codable, Hashable, Sendable {
        public var south: Double
        public var west: Double
        public var north: Double
        public var east: Double

        public init(south: Double, west: Double, north: Double, east: Double) {
            self.south = south
            self.west = west
            self.north = north
            self.east = east
        }

        public func contains(_ coordinate: GeoCoordinate) -> Bool {
            (south...north).contains(coordinate.latitude) && (west...east).contains(coordinate.longitude)
        }

        public func union(_ other: Bounds) -> Bounds {
            Bounds(south: min(south, other.south), west: min(west, other.west), north: max(north, other.north), east: max(east, other.east))
        }
    }

    /// A sight as a package describes it.
    public struct PackageSight: Codable, Hashable, Sendable, Identifiable {
        /// Unique across packages: the same ID is the same place.
        public var id: String
        /// The original name ("Brandenburger Tor").
        public var name: String
        /// Names in other languages where they differ (`{"en": "Brandenburg Gate"}`).
        public var names: [String: String]?
        /// The language of `name` (the package's `language` otherwise).
        public var nameLanguage: String?
        public var category: SightCategory
        public var latitude: Double
        public var longitude: Double
        public var radius: Double?
        public var district: String?
        /// The Wikidata item ("Q82425"): places with the same item are one place.
        public var wikidata: String?
        /// IDs (in other packages) of the same place: this sight becomes theirs.
        public var sameAs: [String]?
        /// The chronicle dating it (the package's first otherwise).
        public var chronicle: String?
        /// Its entry by language (`"en"`, `"de"`): title, url, text, image.
        public var entry: [String: SightInfo]?
        public var facts: Facts?

        public init(id: String, name: String, names: [String: String]? = nil, nameLanguage: String? = nil,
                    category: SightCategory, latitude: Double, longitude: Double, radius: Double? = nil,
                    district: String? = nil, wikidata: String? = nil, sameAs: [String]? = nil, chronicle: String? = nil,
                    entry: [String: SightInfo]? = nil, facts: Facts? = nil) {
            self.id = id
            self.name = name
            self.names = names
            self.nameLanguage = nameLanguage
            self.category = category
            self.latitude = latitude
            self.longitude = longitude
            self.radius = radius
            self.district = district
            self.wikidata = wikidata
            self.sameAs = sameAs
            self.chronicle = chronicle
            self.entry = entry
            self.facts = facts
        }
    }

    /// A sight's historical facts: the year (which dates it in its chronicle), the part
    /// of a divided place it lay in, and the phrases by language.
    public struct Facts: Codable, Hashable, Sendable {
        public var year: Int?
        public var sector: String?
        public var wikidata: URL?
        public var localized: [String: FactTexts]

        public init(year: Int? = nil, sector: String? = nil, wikidata: URL? = nil, localized: [String: FactTexts] = [:]) {
            self.year = year
            self.sector = sector
            self.wikidata = wikidata
            self.localized = localized
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            year = try container.decodeIfPresent(Int.self, forKey: .year)
            sector = try container.decodeIfPresent(String.self, forKey: .sector)
            wikidata = try container.decodeIfPresent(URL.self, forKey: .wikidata)
            localized = try container.decodeIfPresent([String: FactTexts].self, forKey: .localized) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(year, forKey: .year)
            try container.encodeIfPresent(sector, forKey: .sector)
            try container.encodeIfPresent(wikidata, forKey: .wikidata)
            if !localized.isEmpty { try container.encode(localized, forKey: .localized) }
        }

        enum CodingKeys: String, CodingKey { case year, sector, wikidata, localized }
    }

    /// The facts in one language. Achievement rules read the English ones (styles,
    /// architects and clients by name).
    public struct FactTexts: Codable, Hashable, Sendable {
        public var built: String?
        public var opened: String?
        public var styles: [String]?
        public var architects: [String]?
        public var commissionedBy: [String]?
        /// The history of the place: paragraphs separated by blank lines.
        public var history: String?

        public init(built: String? = nil, opened: String? = nil, styles: [String]? = nil, architects: [String]? = nil,
                    commissionedBy: [String]? = nil, history: String? = nil) {
            self.built = built
            self.opened = opened
            self.styles = styles
            self.architects = architects
            self.commissionedBy = commissionedBy
            self.history = history
        }
    }

    /// Places of remembrance as chapters of history and walks (outside the game).
    public struct Remembrance: Codable, Hashable, Sendable {
        public struct Place: Codable, Hashable, Sendable {
            public var sight: String
            public var remembers: LocalizedText
        }

        public struct Chapter: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var title: LocalizedText
            public var years: LocalizedText?
            public var text: LocalizedText
            public var places: [Place]
        }

        public struct Tour: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var title: LocalizedText
            public var text: LocalizedText
            public var stops: [String]
        }

        public var chapters: [Chapter]
        public var tours: [Tour]?

        public init(chapters: [Chapter], tours: [Tour]? = nil) {
            self.chapters = chapters
            self.tours = tours
        }
    }

    /// Stations collected by going there, and their lines.
    public struct Transit: Codable, Hashable, Sendable {
        public var stations: [Station]
        public var lines: [TransitLine]

        public init(stations: [Station], lines: [TransitLine]) {
            self.stations = stations
            self.lines = lines
        }
    }

    /// Reverse-DNS style, unique ("mapquest.berlin.churches").
    public var id: String
    /// Newer versions replace older ones; compared part by part ("2026.11.18", "1.2.0").
    public var version: String
    public var title: LocalizedText
    public var summary: LocalizedText?
    public var publisher: String?
    public var homepage: URL?
    /// Licences of the content (texts, photos, positions).
    public var license: String?
    /// The language of the sights' original names ("de").
    public var language: String?
    public var region: Region?
    /// Packages this one builds on: its achievements count their sights too.
    public var includes: [String]?
    public var categories: [CategoryDefinition]?
    public var chronicles: [Chronicle]?
    public var sights: [PackageSight]?
    public var achievements: [Achievement]?
    public var remembrance: Remembrance?
    public var transit: Transit?

    public init(id: String, version: String, title: LocalizedText, summary: LocalizedText? = nil, publisher: String? = nil,
                homepage: URL? = nil, license: String? = nil, language: String? = nil, region: Region? = nil,
                includes: [String]? = nil, categories: [CategoryDefinition]? = nil, chronicles: [Chronicle]? = nil,
                sights: [PackageSight]? = nil, achievements: [Achievement]? = nil, remembrance: Remembrance? = nil,
                transit: Transit? = nil) {
        self.id = id
        self.version = version
        self.title = title
        self.summary = summary
        self.publisher = publisher
        self.homepage = homepage
        self.license = license
        self.language = language
        self.region = region
        self.includes = includes
        self.categories = categories
        self.chronicles = chronicles
        self.sights = sights
        self.achievements = achievements
        self.remembrance = remembrance
        self.transit = transit
    }

    /// Whether `version` is newer than `other` (numeric parts compared as numbers).
    public static func isVersion(_ version: String, newerThan other: String) -> Bool {
        let a = version.split(whereSeparator: { $0 == "." || $0 == "-" }), b = other.split(whereSeparator: { $0 == "." || $0 == "-" })
        for (x, y) in zip(a, b) where x != y {
            if let i = Int(x), let j = Int(y) { return i > j }
            return x > y
        }
        return a.count > b.count
    }

    /// What is wrong with the package itself (duplicate IDs, impossible positions):
    /// such packages are not installed.
    public func problems() -> [String] {
        var problems: [String] = []
        if id.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("the package has no ID") }
        if version.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(id) has no version") }
        func duplicates(_ ids: [String], _ kind: String) {
            var seen = Set<String>()
            for id in ids where !seen.insert(id).inserted { problems.append("\(kind) \(id) twice") }
        }
        duplicates((sights ?? []).map(\.id), "sight")
        duplicates((achievements ?? []).map(\.id), "achievement")
        duplicates((chronicles ?? []).map(\.id), "chronicle")
        duplicates((transit?.stations ?? []).map(\.id), "station")
        for sight in sights ?? [] {
            if !(-90...90).contains(sight.latitude) || !(-180...180).contains(sight.longitude) {
                problems.append("sight \(sight.id) has no valid position")
            }
            if let radius = sight.radius, !(radius > 0) { problems.append("sight \(sight.id) has no valid radius") }
            if sight.id.isEmpty { problems.append("a sight has no ID") }
        }
        return problems
    }
}

/// Sight package files: one package, or several in a bundle
/// (`{"format": "mapquest-sights", "formatVersion": 1, "packages": […]}`).
public enum SightPackageFile {
    public static let format = "mapquest-sights"
    public static let formatVersion = 1

    public enum FileError: Error, Equatable, LocalizedError {
        case notASightPackage
        case newerFormat(Int)
        case unreadable(String)
        case invalid([String])

        public var errorDescription: String? {
            switch self {
            case .notASightPackage: return "This is not a sight package." // not localized: the app shows its own text
            case .newerFormat(let version): return "Sight package format \(version) is newer than this app's." // not localized
            case .unreadable(let detail): return "The sight package could not be read: \(detail)" // not localized
            case .invalid(let problems): return problems.joined(separator: "; ") // not localized
            }
        }
    }

    private struct Header: Decodable {
        var format: String?
        var formatVersion: Int?
        var packages: [SightPackage]?
    }

    /// The packages in a file, checked (`SightPackage.problems`).
    public static func decode(_ data: Data) throws -> [SightPackage] {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw FileError.unreadable(String(describing: error))
        }
        guard header.format == format else { throw FileError.notASightPackage }
        if let version = header.formatVersion, version > formatVersion { throw FileError.newerFormat(version) }
        let packages: [SightPackage]
        do {
            packages = try header.packages ?? [JSONDecoder().decode(SightPackage.self, from: data)]
        } catch {
            throw FileError.unreadable(Self.describe(error))
        }
        let problems = packages.flatMap { $0.problems() }
        guard problems.isEmpty else { throw FileError.invalid(problems) }
        return packages
    }

    /// One package as a package file, several as a bundle.
    public static func encode(_ packages: [SightPackage]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        struct Bundle: Encodable {
            var format = SightPackageFile.format
            var formatVersion = SightPackageFile.formatVersion
            var packages: [SightPackage]
        }
        struct Single: Encodable {
            var package: SightPackage
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(SightPackageFile.format, forKey: .format)
                try container.encode(SightPackageFile.formatVersion, forKey: .formatVersion)
                try package.encode(to: encoder)
            }
            enum Key: String, CodingKey { case format, formatVersion }
        }
        if packages.count == 1 {
            return try encoder.encode(Single(package: packages[0]))
        }
        return try encoder.encode(Bundle(packages: packages))
    }

    /// "sights[3].latitude: …" for a decoding error.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context)): missing \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default: return String(describing: error)
        }
    }
}
