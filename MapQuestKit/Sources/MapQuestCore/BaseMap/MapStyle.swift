import Foundation

/// What a map feature is drawn as; colours per style in `MapPalette`.
public enum MapRole: Int, CaseIterable, Hashable, Sendable {
    case land
    case residential, commercial, industrial, institutional, cemetery, sports
    case farmland, grass, wood, wetland, bare
    case water
    case aeroway, pedestrian
    case building, buildingOutline
    case tunnel, roadCasing
    case motorway, trunk, primary, secondary, tertiary, minor, service, track, path, rail
}

/// An 8-bit colour.
public struct MapColor: Hashable, Sendable {
    public var red: UInt8, green: UInt8, blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The colours of one map style.
public struct MapPalette: Sendable {
    private let colors: [MapRole: MapColor]

    public init(_ colors: [MapRole: MapColor]) {
        self.colors = colors
    }

    public func color(_ role: MapRole) -> MapColor {
        colors[role] ?? MapColor(255, 0, 255)
    }

    /// Colourful streets, parks and water (OpenStreetMap-like, softened).
    public static let streets = MapPalette([
        .land: MapColor(242, 239, 233), .residential: MapColor(231, 226, 220), .commercial: MapColor(242, 222, 220),
        .industrial: MapColor(235, 222, 232), .institutional: MapColor(250, 247, 222), .cemetery: MapColor(184, 210, 186),
        .sports: MapColor(184, 226, 206), .farmland: MapColor(238, 240, 213), .grass: MapColor(205, 235, 176),
        .wood: MapColor(173, 209, 158), .wetland: MapColor(206, 226, 214), .bare: MapColor(238, 229, 210),
        .water: MapColor(170, 211, 223), .aeroway: MapColor(210, 210, 222), .pedestrian: MapColor(226, 225, 234),
        .building: MapColor(217, 208, 201), .buildingOutline: MapColor(196, 184, 174), .tunnel: MapColor(226, 222, 216),
        .roadCasing: MapColor(188, 182, 176), .motorway: MapColor(232, 146, 162), .trunk: MapColor(249, 178, 156),
        .primary: MapColor(252, 214, 164), .secondary: MapColor(247, 250, 191), .tertiary: MapColor(255, 255, 255),
        .minor: MapColor(255, 255, 255), .service: MapColor(255, 255, 255), .track: MapColor(172, 142, 108),
        .path: MapColor(214, 150, 132), .rail: MapColor(150, 150, 150),
    ])

    /// Light grey.
    public static let light = MapPalette([
        .land: MapColor(245, 245, 243), .residential: MapColor(238, 238, 236), .commercial: MapColor(239, 236, 236),
        .industrial: MapColor(236, 235, 239), .institutional: MapColor(241, 241, 236), .cemetery: MapColor(226, 234, 226),
        .sports: MapColor(226, 236, 230), .farmland: MapColor(243, 243, 239), .grass: MapColor(229, 238, 226),
        .wood: MapColor(219, 233, 217), .wetland: MapColor(229, 236, 233), .bare: MapColor(240, 238, 232),
        .water: MapColor(210, 221, 230), .aeroway: MapColor(228, 228, 232), .pedestrian: MapColor(238, 238, 238),
        .building: MapColor(228, 226, 224), .buildingOutline: MapColor(214, 211, 209), .tunnel: MapColor(238, 238, 238),
        .roadCasing: MapColor(216, 216, 216), .motorway: MapColor(255, 255, 255), .trunk: MapColor(255, 255, 255),
        .primary: MapColor(255, 255, 255), .secondary: MapColor(255, 255, 255), .tertiary: MapColor(255, 255, 255),
        .minor: MapColor(255, 255, 255), .service: MapColor(255, 255, 255), .track: MapColor(218, 216, 212),
        .path: MapColor(222, 220, 218), .rail: MapColor(204, 204, 204),
    ])

    /// Dark.
    public static let dark = MapPalette([
        .land: MapColor(24, 26, 30), .residential: MapColor(30, 32, 36), .commercial: MapColor(35, 32, 36),
        .industrial: MapColor(32, 32, 38), .institutional: MapColor(35, 35, 32), .cemetery: MapColor(28, 38, 30),
        .sports: MapColor(28, 38, 34), .farmland: MapColor(28, 30, 30), .grass: MapColor(28, 40, 32),
        .wood: MapColor(24, 40, 30), .wetland: MapColor(26, 36, 36), .bare: MapColor(36, 34, 30),
        .water: MapColor(18, 32, 48), .aeroway: MapColor(44, 44, 52), .pedestrian: MapColor(40, 40, 44),
        .building: MapColor(44, 44, 48), .buildingOutline: MapColor(56, 56, 60), .tunnel: MapColor(38, 38, 42),
        .roadCasing: MapColor(16, 16, 18), .motorway: MapColor(112, 92, 72), .trunk: MapColor(98, 86, 72),
        .primary: MapColor(86, 82, 74), .secondary: MapColor(74, 74, 74), .tertiary: MapColor(68, 68, 70),
        .minor: MapColor(60, 60, 64), .service: MapColor(54, 54, 58), .track: MapColor(70, 64, 58),
        .path: MapColor(72, 66, 62), .rail: MapColor(84, 84, 88),
    ])
}

/// A point in pixels of a drawn tile (origin top left, y down).
public struct MapPixel: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One drawing step: shapes of one role, filled or stroked.
public struct MapDrawCommand: Sendable {
    public enum Kind: Hashable, Sendable {
        case fill
        /// Width and dash pattern in pixels.
        case stroke(width: Double, dash: [Double]?)
    }

    public var role: MapRole
    public var kind: Kind
    /// Fills: one entry per feature with its rings (filled even-odd per feature).
    /// Strokes: one entry per feature with its lines.
    public var shapes: [[[MapPixel]]]
}

/// The label-free map style: which features of an OpenMapTiles vector tile are
/// drawn, how and in which order. Names, house numbers, POIs and all other
/// point features are left out by design.
public enum MapRenderPlan {
    /// The vector tile layers that are drawn.
    public static let layers: Set<String> = ["landuse", "landcover", "water", "waterway", "aeroway", "transportation", "building"]

    /// Drawing steps for `target` (a tile at `source`'s zoom or deeper, inside it)
    /// from the vector tile of `source`, `size` pixels square.
    public static func commands(for tile: VectorTile, source: TileKey, target: TileKey, size: Double = 512) -> [MapDrawCommand] {
        precondition(target.zoom >= source.zoom, "the target lies inside the source tile")
        let zoom = target.zoom
        let scale = size / 256  // pixels per point
        let factor = Double(1 << (target.zoom - source.zoom))
        let offsetX = Double(target.x) - Double(source.x) * factor
        let offsetY = Double(target.y) - Double(source.y) * factor
        var steps: [Step: [[[MapPixel]]]] = [:]

        func add(_ feature: VectorTile.Feature, extent: Int, to step: Step, padding: Double) {
            let k = factor / Double(extent)
            var shape: [[MapPixel]] = []
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for path in feature.paths {
                var pixels: [MapPixel] = []
                pixels.reserveCapacity(path.count)
                for (index, point) in path.enumerated() {
                    let p = MapPixel(x: (Double(point.x) * k - offsetX) * size, y: (Double(point.y) * k - offsetY) * size)
                    // Vertices closer than half a pixel add nothing (the last one is always kept).
                    if let last = pixels.last, index < path.count - 1,
                       abs(p.x - last.x) < 0.5, abs(p.y - last.y) < 0.5 { continue }
                    pixels.append(p)
                    minX = min(minX, p.x); maxX = max(maxX, p.x)
                    minY = min(minY, p.y); maxY = max(maxY, p.y)
                }
                if pixels.count > 1 { shape.append(pixels) }
            }
            // Only shapes reaching into the tile.
            guard !shape.isEmpty, maxX >= -padding, maxY >= -padding, minX <= size + padding, minY <= size + padding else { return }
            steps[step, default: []].append(shape)
        }

        for (name, layer) in tile.layers {
            for feature in layer.features where feature.type != .point && feature.type != .unknown {
                let isPolygon = feature.type == .polygon
                switch name {
                case "landuse":
                    if isPolygon, let role = landuseRole(feature.className) { add(feature, extent: layer.extent, to: Step(.landuse, role, .fill), padding: 0) }
                case "landcover":
                    if isPolygon, let role = landcoverRole(feature.className) { add(feature, extent: layer.extent, to: Step(.landcover, role, .fill), padding: 0) }
                case "water":
                    if isPolygon { add(feature, extent: layer.extent, to: Step(.water, .water, .fill), padding: 0) }
                case "waterway":
                    guard !isPolygon, feature.properties["brunnel"]?.string != "tunnel" else { continue }
                    let isRiver = ["river", "canal"].contains(feature.className ?? "")
                    if let width = width(isRiver ? riverWidths : streamWidths, zoom: zoom) {
                        add(feature, extent: layer.extent, to: Step(.waterway, .water, .stroke(width: width * scale, dash: nil)), padding: width * scale)
                    }
                case "aeroway":
                    if isPolygon {
                        if feature.className != "aerodrome" { add(feature, extent: layer.extent, to: Step(.aeroway, .aeroway, .fill), padding: 0) }
                    } else if let width = width(feature.className == "runway" ? runwayWidths : taxiwayWidths, zoom: zoom) {
                        add(feature, extent: layer.extent, to: Step(.aeroway, .aeroway, .stroke(width: width * scale, dash: nil)), padding: width * scale)
                    }
                case "building":
                    guard isPolygon, zoom >= 14 else { continue }
                    add(feature, extent: layer.extent, to: Step(.building, .building, .fill), padding: 0)
                    if zoom >= 15 {
                        add(feature, extent: layer.extent, to: Step(.buildingOutline, .buildingOutline, .stroke(width: 0.5 * scale, dash: nil)), padding: 1)
                    }
                case "transportation":
                    if isPolygon {
                        if zoom >= 14 { add(feature, extent: layer.extent, to: Step(.pedestrian, .pedestrian, .fill), padding: 0) }
                        continue
                    }
                    guard let road = RoadClass(feature.className), let width = width(road.widths, zoom: zoom) else { continue }
                    let pixels = width * scale
                    switch feature.properties["brunnel"]?.string {
                    case "tunnel":
                        guard road != .rail else { continue }
                        add(feature, extent: layer.extent, to: Step(.tunnels, .tunnel, .stroke(width: pixels, dash: nil), rank: road.rank), padding: pixels)
                    default:
                        let group: Group = feature.properties["brunnel"]?.string == "bridge" ? .bridges : .roads
                        if let casing = road.casing(width, zoom: zoom) {
                            add(feature, extent: layer.extent, to: Step(group, .roadCasing, .stroke(width: casing * scale, dash: nil), rank: road.rank, casing: true), padding: casing * scale)
                        }
                        add(feature, extent: layer.extent, to: Step(group, road.role, .stroke(width: pixels, dash: road.dash(pixels)), rank: road.rank), padding: pixels)
                    }
                default:
                    continue
                }
            }
        }
        return steps.keys.sorted().compactMap { step in
            guard let shapes = steps[step], !shapes.isEmpty else { return nil }
            return MapDrawCommand(role: step.role, kind: step.kind, shapes: shapes)
        }
    }

    // MARK: Order

    /// Drawing order: groups, then rank inside the group (casings below fills).
    private enum Group: Int, Comparable {
        case landuse, landcover, water, waterway, aeroway, pedestrian, building, buildingOutline, tunnels, roads, bridges

        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    private struct Step: Hashable, Comparable {
        var group: Group
        var role: MapRole
        var kind: MapDrawCommand.Kind
        var rank: Int
        var casing: Bool

        init(_ group: Group, _ role: MapRole, _ kind: MapDrawCommand.Kind, rank: Int = 0, casing: Bool = false) {
            self.group = group
            self.role = role
            self.kind = kind
            self.rank = rank
            self.casing = casing
        }

        static func < (a: Step, b: Step) -> Bool {
            if a.group != b.group { return a.group < b.group }
            // Roads: all casings first, then the fills from minor to major.
            if a.casing != b.casing { return a.casing }
            if a.rank != b.rank { return a.rank < b.rank }
            if a.role != b.role { return a.role.rawValue < b.role.rawValue }
            return a.kind.sortKey < b.kind.sortKey
        }
    }

    // MARK: Classes

    private static func landuseRole(_ className: String?) -> MapRole? {
        switch className {
        case "residential": return .residential
        case "commercial", "retail": return .commercial
        case "industrial", "garages", "railway", "dam": return .industrial
        case "school", "university", "kindergarten", "college", "library", "hospital", "bus_station": return .institutional
        case "cemetery": return .cemetery
        case "stadium", "pitch", "playground", "track", "theme_park", "zoo": return .sports
        case "quarry": return .bare
        default: return nil  // suburb, quarter, neighbourhood (place areas), military, …
        }
    }

    private static func landcoverRole(_ className: String?) -> MapRole? {
        switch className {
        case "farmland": return .farmland
        case "grass": return .grass
        case "wood": return .wood
        case "wetland": return .wetland
        case "sand", "rock", "ice": return .bare
        default: return nil
        }
    }

    private enum RoadClass: Int {
        case path, track, rail, service, minor, tertiary, secondary, primary, trunk, motorway

        init?(_ className: String?) {
            switch className {
            case "motorway": self = .motorway
            case "trunk": self = .trunk
            case "primary": self = .primary
            case "secondary": self = .secondary
            case "tertiary": self = .tertiary
            case "minor": self = .minor
            case "service", "busway", "raceway": self = .service
            case "track": self = .track
            case "path": self = .path
            case "rail", "transit": self = .rail
            default: return nil  // ferry, construction, …
            }
        }

        var rank: Int { rawValue }

        var role: MapRole {
            switch self {
            case .motorway: return .motorway
            case .trunk: return .trunk
            case .primary: return .primary
            case .secondary: return .secondary
            case .tertiary: return .tertiary
            case .minor: return .minor
            case .service: return .service
            case .track: return .track
            case .path: return .path
            case .rail: return .rail
            }
        }

        var widths: [(zoom: Int, width: Double)] {
            switch self {
            case .motorway: return [(5, 0.6), (9, 1.6), (12, 3.5), (14, 6), (16, 12), (18, 30), (20, 80)]
            case .trunk: return [(6, 0.5), (9, 1.4), (12, 3), (14, 5.5), (16, 11), (18, 26), (20, 70)]
            case .primary: return [(8, 0.6), (10, 1.2), (12, 2.6), (14, 5), (16, 10), (18, 24), (20, 64)]
            case .secondary: return [(9, 0.5), (11, 1), (12, 2), (14, 4.5), (16, 9), (18, 22), (20, 58)]
            case .tertiary: return [(11, 0.5), (12, 1.2), (14, 3.8), (16, 8), (18, 20), (20, 52)]
            case .minor: return [(13, 0.6), (14, 2.4), (16, 6), (18, 15), (20, 40)]
            case .service: return [(14, 0.8), (16, 3), (18, 8), (20, 20)]
            case .track: return [(14, 0.6), (16, 1.2), (18, 2.4), (20, 4)]
            case .path: return [(14, 0.5), (16, 1), (18, 2), (20, 3)]
            case .rail: return [(10, 0.4), (14, 1.2), (16, 2), (18, 3), (20, 5)]
            }
        }

        /// Casing width (points) around wider roads from zoom 12 (minor roads from 14).
        func casing(_ width: Double, zoom: Int) -> Double? {
            switch self {
            case .path, .track, .rail: return nil
            case .service, .minor: return zoom >= 14 ? width + max(1, 0.2 * width) : nil
            default: return zoom >= 12 ? width + max(1, 0.2 * width) : nil
            }
        }

        func dash(_ pixels: Double) -> [Double]? {
            switch self {
            case .path, .track: return [max(3, 3 * pixels), max(2, 2 * pixels)]
            default: return nil
            }
        }
    }

    private static let riverWidths: [(zoom: Int, width: Double)] = [(8, 0.5), (12, 1.5), (14, 3), (16, 6), (18, 12), (20, 24)]
    private static let streamWidths: [(zoom: Int, width: Double)] = [(12, 0.4), (14, 1), (16, 2), (18, 4), (20, 8)]
    private static let runwayWidths: [(zoom: Int, width: Double)] = [(10, 1), (14, 8), (16, 20), (18, 50), (20, 120)]
    private static let taxiwayWidths: [(zoom: Int, width: Double)] = [(12, 0.5), (14, 2), (16, 5), (18, 12), (20, 30)]

    /// Width in points at `zoom` (exponential between stops, doubling per zoom beyond
    /// the last); `nil` below the first stop (not drawn).
    static func width(_ stops: [(zoom: Int, width: Double)], zoom: Int) -> Double? {
        guard let first = stops.first, let last = stops.last, zoom >= first.zoom else { return nil }
        if zoom >= last.zoom { return last.width * pow(2, Double(zoom - last.zoom)) }
        for (a, b) in zip(stops, stops.dropFirst()) where zoom >= a.zoom && zoom <= b.zoom {
            let t = Double(zoom - a.zoom) / Double(b.zoom - a.zoom)
            return exp(log(a.width) + t * (log(b.width) - log(a.width)))
        }
        return last.width
    }
}

private extension MapDrawCommand.Kind {
    /// Fills before strokes, wider strokes first.
    var sortKey: Double {
        switch self {
        case .fill: return -1
        case let .stroke(width, _): return 1_000 - width
        }
    }
}

/// The relevant part of a TileJSON document (where the vector tiles are).
public struct TileJSON: Codable, Equatable, Sendable {
    public var tiles: [String]
    public var minzoom: Int?
    public var maxzoom: Int?

    public init(tiles: [String], minzoom: Int? = nil, maxzoom: Int? = nil) {
        self.tiles = tiles
        self.minzoom = minzoom
        self.maxzoom = maxzoom
    }

    /// The URL of a tile from the first template (`{z}`, `{x}`, `{y}`).
    public func url(for tile: TileKey) -> URL? {
        guard let template = tiles.first else { return nil }
        let string = template
            .replacingOccurrences(of: "{z}", with: String(tile.zoom))
            .replacingOccurrences(of: "{x}", with: String(tile.x))
            .replacingOccurrences(of: "{y}", with: String(tile.y))
        return URL(string: string)
    }
}
