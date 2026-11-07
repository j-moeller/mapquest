import Foundation

/// A building as an LoD1 block: a footprint extruded from `minHeight` to `height`.
public struct Building: Hashable, Sendable, Identifiable {
    /// How the height was determined.
    public enum HeightSource: Int, Hashable, Sendable, Codable {
        /// From a `height` tag.
        case tagged = 0
        /// From `building:levels` (and roof levels).
        case levels = 1
        /// Estimated from the building type.
        case estimated = 2
    }

    /// Stable identifier, e.g. the OSM way ID (relations are stored negated).
    public var id: Int64
    /// Footprint in world coordinates (courtyards as holes).
    public var footprint: WorldPolygon
    /// Height of the roof top above ground, in metres.
    public var height: Double
    /// Height above ground where the building starts (> 0 for bridges, passages, overhangs).
    public var minHeight: Double
    public var heightSource: HeightSource
    public var name: String?

    public init(
        id: Int64, footprint: WorldPolygon, height: Double, minHeight: Double = 0,
        heightSource: HeightSource = .tagged, name: String? = nil
    ) {
        self.id = id
        self.footprint = footprint
        self.height = height
        self.minHeight = minHeight
        self.heightSource = heightSource
        self.name = name
    }

    public var bounds: WorldRect { footprint.bounds }
}

/// Provides buildings for an area. Implementations: bundled/cached databases,
/// on-demand downloads (OpenStreetMap via Overpass), in-memory test data.
public protocol BuildingSource: Sendable {
    /// All buildings whose footprint may intersect `rect` (world coordinates).
    func buildings(in rect: WorldRect) async throws -> [Building]
}

public enum BuildingSourceError: Error, Equatable {
    /// Building data for the area is not available (e.g. offline and not cached).
    case unavailable(String)
}

/// A fixed set of buildings, indexed by storage tile.
public struct InMemoryBuildingSource: BuildingSource {
    public let buildings: [Building]
    private let index: [TileKey: [Int]]

    public init(_ buildings: [Building]) {
        self.buildings = buildings
        var index: [TileKey: [Int]] = [:]
        for (i, building) in buildings.enumerated() {
            for tile in TileRange(covering: building.bounds, zoom: DiscoveryGrid.zoom) {
                index[tile, default: []].append(i)
            }
        }
        self.index = index
    }

    public func buildings(in rect: WorldRect) -> [Building] {
        var seen = Set<Int>()
        var result: [Building] = []
        for tile in TileRange(covering: rect, zoom: DiscoveryGrid.zoom) {
            for i in index[tile] ?? [] where seen.insert(i).inserted && buildings[i].bounds.intersects(rect) {
                result.append(buildings[i])
            }
        }
        return result
    }
}

/// Ground elevation (metres above mean sea level).
public protocol TerrainModel: Sendable {
    func elevation(at point: WorldPoint) -> Double
}

/// Flat ground at a constant elevation. Berlin lies 30–60 m above sea level
/// (Spree valley ≈ 34 m); local relief within a view radius is small.
public struct FlatTerrain: TerrainModel {
    public var elevation: Double

    public init(elevation: Double) { self.elevation = elevation }

    public func elevation(at point: WorldPoint) -> Double { elevation }

    /// Typical ground elevation of central Berlin.
    public static let berlin = FlatTerrain(elevation: 35)
}
