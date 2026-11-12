import Foundation

/// What kind of place a sight is (icons and grouping).
public enum SightCategory: String, Codable, CaseIterable, Sendable {
    case landmark, museum, palace, church, viewpoint, memorial, park, square, culture, monument, zoo, bridge, stadium
    case fountain, market, government, cemetery, club

    /// Places of remembrance – memorials and memorial sites, cemeteries – are not
    /// part of the game: they are not captured, count for no achievement, and
    /// their entries are open to all.
    public var isRemembrance: Bool { self == .memorial || self == .cemetery }

    /// Unknown categories (newer data) count as landmarks.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SightCategory(rawValue: raw) ?? .landmark
    }
}

/// A place worth visiting. It is captured once you have been there: once the
/// area discovered around your positions (the radius view) covers its position –
/// or, for large open areas, reaches within `captureTolerance` of it.
public struct Sight: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var category: SightCategory
    public var latitude: Double
    public var longitude: Double
    /// The extent of the sight around its position, in metres (larger for open areas).
    public var radius: Double
    /// The city district it lies in (e.g. "Friedrichshain-Kreuzberg"), if known.
    public var district: String?

    public init(id: String, name: String, category: SightCategory, latitude: Double, longitude: Double, radius: Double = 40,
                district: String? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.district = district
    }

    /// A place of remembrance (a memorial, a memorial site, a cemetery): not part of the game.
    public var isPlaceOfRemembrance: Bool { category.isRemembrance }

    /// How close the discovered area (circles of 50 m around positions) must come to
    /// the position: 0 – it must cover it – except for sights larger than the circles.
    public var captureTolerance: Double { max(0, radius - 50) }

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

    /// Reads a sight list: `{"source": …, "sights": [{id, name, category, latitude, longitude, radius, district}]}`.
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
