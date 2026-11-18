import Foundation

/// U-Bahn or S-Bahn.
public enum TransitSystem: String, Codable, CaseIterable, Hashable, Sendable {
    case ubahn = "U"
    case sbahn = "S"

    public var title: String {
        switch self {
        case .ubahn: return "U-Bahn"
        case .sbahn: return "S-Bahn"
        }
    }
}

/// A U-Bahn or S-Bahn station: collected by going there (no photo needed). The
/// U-Bahn and S-Bahn stations of one place (e.g. Alexanderplatz) are two stations.
public struct Station: Codable, Hashable, Identifiable, Sendable {
    /// "u:alexanderplatz", "s:alexanderplatz".
    public var id: String
    /// The station's name, German as on the signs ("Hauptbahnhof").
    public var name: String
    /// An English explanation of the name, for the few that need one ("Central Station").
    public var englishName: String?
    public var system: TransitSystem
    /// The lines stopping here, e.g. ["U2", "U5", "U8"].
    public var lines: [String]
    public var latitude: Double
    public var longitude: Double
    /// The extent of the station around its position, in metres (platforms are long).
    public var radius: Double
    /// The district it lies in; `nil` outside the city.
    public var district: String?

    enum CodingKeys: String, CodingKey {
        case id, name, names, system, lines, latitude, longitude, radius, district
    }

    /// Package JSON: `name` as on the signs, `names` explanations by language (`{"en": "Central Station"}`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        englishName = try c.decodeIfPresent([String: String].self, forKey: .names)?["en"]
        system = try c.decode(TransitSystem.self, forKey: .system)
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 80
        district = try c.decodeIfPresent(String.self, forKey: .district)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if let englishName { try c.encode(["en": englishName], forKey: .names) }
        try c.encode(system, forKey: .system)
        try c.encode(lines, forKey: .lines)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encode(radius, forKey: .radius)
        try c.encodeIfPresent(district, forKey: .district)
    }

    public init(id: String, name: String, englishName: String? = nil, system: TransitSystem, lines: [String],
                latitude: Double, longitude: Double, radius: Double = 80, district: String? = nil) {
        self.id = id
        self.name = name
        self.englishName = englishName
        self.system = system
        self.lines = lines
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.district = district
    }

    /// Both names: the German one always first ("Hauptbahnhof · Central Station").
    public var names: BilingualName { BilingualName(german: name, english: englishName, germanFirst: true) }

    /// The English explanation, in English.
    public var otherName: String? { names.secondary() }

    /// As for sights: the circles of the radius view must reach within this many metres.
    public var captureTolerance: Double { max(0, radius - 50) }

    public var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }
    public var point: WorldPoint { WebMercator.project(coordinate) }
}

/// A U-Bahn or S-Bahn line with its stations in order.
public struct TransitLine: Codable, Hashable, Identifiable, Sendable {
    /// "U2", "S41".
    public var id: String
    public var system: TransitSystem
    /// "#DA421E".
    public var colour: String
    /// "Pankow – Ruhleben", "Ringbahn".
    public var name: String
    public var stations: [String]

    public init(id: String, system: TransitSystem, colour: String, name: String, stations: [String]) {
        self.id = id
        self.system = system
        self.colour = colour
        self.name = name
        self.stations = stations
    }

    /// The colour as RGB components 0…1.
    public var rgb: (red: Double, green: Double, blue: Double) {
        let hex = colour.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return (0.5, 0.5, 0.5) }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

/// The stations and lines of one or more cities (`<city>-stations.json`).
public struct StationCatalog: Sendable {
    public private(set) var stations: [Station]
    public private(set) var lines: [TransitLine]
    private var index: [String: Int]

    public init(stations: [Station] = [], lines: [TransitLine] = []) {
        var unique: [Station] = []
        var index: [String: Int] = [:]
        for station in stations where index[station.id] == nil {
            index[station.id] = unique.count
            unique.append(station)
        }
        self.stations = unique
        self.index = index
        var seen: Set<String> = []
        self.lines = lines.filter { seen.insert($0.id).inserted }
    }

    /// Reads `{"source": …, "lines": [{id, system, colour, name, stations}], "stations": [{id, name, system, lines, latitude, longitude, radius, district}]}`.
    public static func decode(_ data: Data) throws -> StationCatalog {
        struct Document: Decodable {
            var lines: [TransitLine]
            var stations: [Station]
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        return StationCatalog(stations: document.stations, lines: document.lines)
    }

    public static func merged(_ catalogs: [StationCatalog]) -> StationCatalog {
        StationCatalog(stations: catalogs.flatMap(\.stations), lines: catalogs.flatMap(\.lines))
    }

    public subscript(id: String) -> Station? {
        index[id].map { stations[$0] }
    }

    public func line(_ id: String) -> TransitLine? {
        lines.first { $0.id == id }
    }

    public var count: Int { stations.count }
}
