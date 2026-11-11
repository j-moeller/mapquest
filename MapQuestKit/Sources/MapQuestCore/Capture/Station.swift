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
    public var name: String
    public var system: TransitSystem
    /// The lines stopping here, e.g. ["U2", "U5", "U8"].
    public var lines: [String]
    public var latitude: Double
    public var longitude: Double
    /// The extent of the station around its position, in metres (platforms are long).
    public var radius: Double
    /// The district it lies in; `nil` outside the city.
    public var district: String?

    public init(id: String, name: String, system: TransitSystem, lines: [String], latitude: Double, longitude: Double,
                radius: Double = 80, district: String? = nil) {
        self.id = id
        self.name = name
        self.system = system
        self.lines = lines
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.district = district
    }

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
