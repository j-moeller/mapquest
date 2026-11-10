import Foundation

/// What kind of place a sight is (icons and grouping).
public enum SightCategory: String, Codable, CaseIterable, Sendable {
    case landmark, museum, palace, church, viewpoint, memorial, park, square, culture, monument, zoo, bridge, stadium

    /// Unknown categories (newer data) count as landmarks.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SightCategory(rawValue: raw) ?? .landmark
    }
}

/// A place worth visiting. It is captured once the discovered area reaches it:
/// any discovered area within `radius` metres of its position.
public struct Sight: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var category: SightCategory
    public var latitude: Double
    public var longitude: Double
    /// How close the discovered area must come, in metres (larger for open areas).
    public var radius: Double

    public init(id: String, name: String, category: SightCategory, latitude: Double, longitude: Double, radius: Double = 40) {
        self.id = id
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }

    public var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }
    public var point: WorldPoint { WebMercator.project(coordinate) }
}

/// The sights of one or more cities (bundled JSON files, `<city>-sights.json`).
public struct SightCatalog: Sendable {
    public private(set) var sights: [Sight]
    private var index: [String: Int]

    public init(sights: [Sight]) {
        var unique: [Sight] = []
        var index: [String: Int] = [:]
        for sight in sights where index[sight.id] == nil {
            index[sight.id] = unique.count
            unique.append(sight)
        }
        self.sights = unique
        self.index = index
    }

    /// Reads a sight list: `{"source": …, "sights": [{id, name, category, latitude, longitude, radius}]}`.
    public static func decode(_ data: Data) throws -> SightCatalog {
        struct Document: Decodable { var sights: [Sight] }
        return SightCatalog(sights: try JSONDecoder().decode(Document.self, from: data).sights)
    }

    /// Several lists together (the first occurrence of an ID wins).
    public static func merged(_ catalogs: [SightCatalog]) -> SightCatalog {
        SightCatalog(sights: catalogs.flatMap(\.sights))
    }

    public subscript(id: String) -> Sight? {
        index[id].map { sights[$0] }
    }

    public var count: Int { sights.count }
}
