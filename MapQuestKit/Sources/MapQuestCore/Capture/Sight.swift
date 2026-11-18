import Foundation

/// What kind of place a sight is (icons, grouping, achievement rules). Packages share
/// a core vocabulary (`SightCategory.allCases`); they can declare more, each under a
/// core parent (`CategoryDefinition`: "chapel" under "church"), so rules and filters
/// for the parent take them in.
public struct SightCategory: RawRepresentable, Hashable, Sendable, Codable, CaseIterable, Comparable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (a: SightCategory, b: SightCategory) -> Bool { a.rawValue < b.rawValue }

    public static let landmark = SightCategory("landmark")
    public static let museum = SightCategory("museum")
    public static let palace = SightCategory("palace")
    public static let church = SightCategory("church")
    public static let viewpoint = SightCategory("viewpoint")
    public static let memorial = SightCategory("memorial")
    public static let park = SightCategory("park")
    public static let square = SightCategory("square")
    public static let culture = SightCategory("culture")
    public static let monument = SightCategory("monument")
    public static let zoo = SightCategory("zoo")
    public static let bridge = SightCategory("bridge")
    public static let stadium = SightCategory("stadium")
    public static let fountain = SightCategory("fountain")
    public static let market = SightCategory("market")
    public static let government = SightCategory("government")
    public static let cemetery = SightCategory("cemetery")
    public static let club = SightCategory("club")

    /// The core vocabulary every package can use without declaring it.
    public static let allCases: [SightCategory] = [
        .landmark, .museum, .palace, .church, .viewpoint, .memorial, .park, .square, .culture, .monument, .zoo,
        .bridge, .stadium, .fountain, .market, .government, .cemetery, .club,
    ]

    public var isCore: Bool { Self.allCases.contains(self) }

    /// Places of remembrance – memorials and memorial sites, cemeteries – are not
    /// part of the game: they are not captured, count for no achievement, and
    /// their entries are open to all. (Declared categories inherit it from their parent.)
    public var isRemembrance: Bool { self == .memorial || self == .cemetery }
}

/// A category a package adds to the core vocabulary.
public struct CategoryDefinition: Codable, Hashable, Sendable {
    public var id: SightCategory
    public var title: LocalizedText
    /// A core (or other declared) category it belongs to: its icon, its rules and filters.
    public var parent: SightCategory?
    /// An SF Symbol (the parent's otherwise).
    public var symbol: String?
    /// Places of remembrance (outside the game); the parent's otherwise.
    public var remembrance: Bool?

    public init(id: SightCategory, title: LocalizedText, parent: SightCategory? = nil, symbol: String? = nil,
                remembrance: Bool? = nil) {
        self.id = id
        self.title = title
        self.parent = parent
        self.symbol = symbol
        self.remembrance = remembrance
    }
}

/// The categories in use: the core vocabulary and what packages declare on top.
public struct CategoryHierarchy: Hashable, Sendable {
    public private(set) var definitions: [SightCategory: CategoryDefinition]

    public init(_ definitions: [CategoryDefinition] = []) {
        var byID: [SightCategory: CategoryDefinition] = [:]
        // The core vocabulary is fixed: packages cannot redefine it.
        for definition in definitions where !definition.id.isCore && byID[definition.id] == nil {
            byID[definition.id] = definition
        }
        self.definitions = byID
    }

    public static let core = CategoryHierarchy()

    /// Whether the category is core or declared.
    public func isKnown(_ category: SightCategory) -> Bool { category.isCore || definitions[category] != nil }

    /// The category and its parents, nearest first (cycles cut).
    public func ancestry(of category: SightCategory) -> [SightCategory] {
        var chain = [category]
        var current = category
        while let parent = definitions[current]?.parent, !chain.contains(parent) {
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// The core category it falls under (unknown ones: landmark).
    public func core(of category: SightCategory) -> SightCategory {
        ancestry(of: category).first(where: \.isCore) ?? .landmark
    }

    /// Whether its places are places of remembrance (outside the game).
    public func isRemembrance(_ category: SightCategory) -> Bool {
        for member in ancestry(of: category) {
            if let flag = definitions[member]?.remembrance { return flag }
            if member.isCore { return member.isRemembrance }
        }
        return false
    }

    /// Whether the category is one of `categories` or lies under one of them.
    public func matches(_ category: SightCategory, any categories: [SightCategory]) -> Bool {
        ancestry(of: category).contains { categories.contains($0) }
    }
}

/// A place worth visiting. It is captured once you have been there: once the
/// area discovered around your positions (the radius view) covers its position –
/// or, for large open areas, reaches within `captureTolerance` of it.
public struct Sight: Hashable, Identifiable, Sendable {
    /// Unique across all packages (the same ID is the same place).
    public var id: String
    /// The original name and its translations ("Brandenburger Tor", en "Brandenburg Gate").
    public var names: BilingualName
    public var category: SightCategory
    public var latitude: Double
    public var longitude: Double
    /// The extent of the sight around its position, in metres (larger for open areas).
    public var radius: Double
    /// The district it lies in (e.g. "Friedrichshain-Kreuzberg"), if known.
    public var district: String?
    /// A place of remembrance: not part of the game (from its category, `CategoryHierarchy`).
    public var isPlaceOfRemembrance: Bool

    public init(id: String, names: BilingualName, category: SightCategory, latitude: Double, longitude: Double,
                radius: Double = 40, district: String? = nil, isPlaceOfRemembrance: Bool? = nil) {
        self.id = id
        self.names = names
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.district = district
        self.isPlaceOfRemembrance = isPlaceOfRemembrance ?? category.isRemembrance
    }

    /// A sight with a German name and an English one where it differs.
    public init(id: String, name: String, englishName: String? = nil, category: SightCategory, latitude: Double,
                longitude: Double, radius: Double = 40, district: String? = nil) {
        self.init(id: id, names: BilingualName(german: name, english: englishName), category: category,
                  latitude: latitude, longitude: longitude, radius: radius, district: district)
    }

    /// The original name.
    public var germanName: String { names.local }
    /// The English name, where English uses another.
    public var englishName: String? { names.english }

    /// The name in the app's language: in English the English name where there is one.
    public var name: String { names.primary() }

    /// The other name, next to it (in English: the German original).
    public var otherName: String? { names.secondary() }

    /// How close the discovered area (circles of 50 m around positions) must come to
    /// the position: 0 – it must cover it – except for sights larger than the circles.
    public var captureTolerance: Double { max(0, radius - 50) }

    public var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }
    public var point: WorldPoint { WebMercator.project(coordinate) }
}

/// The sights of the installed packages (`SightLibrary`).
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

    /// Several catalogs together (the first occurrence of an ID wins).
    public static func merged(_ catalogs: [SightCatalog]) -> SightCatalog {
        SightCatalog(sights: catalogs.flatMap(\.sights))
    }

    public subscript(id: String) -> Sight? {
        index[id].map { sights[$0] }
    }

    public var count: Int { sights.count }
}
