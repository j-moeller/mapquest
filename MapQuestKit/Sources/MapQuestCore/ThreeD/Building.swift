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
        /// Measured: official 3D city model (e.g. Berlin LoD2).
        case measured = 3
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

/// Buildings of an area as far as data is available, with the version of every
/// data tile covering the area (`DataGrid.noData` where none is available).
public struct BuildingCoverage: Sendable {
    public var buildings: [Building]
    public var versions: DataVersions

    public init(buildings: [Building], versions: DataVersions) {
        self.buildings = buildings
        self.versions = versions
    }

    /// Data tiles for which data is available.
    public var coveredTiles: Set<TileKey> { Set(versions.filter { $0.value != DataGrid.noData }.keys) }
}

/// Provides buildings for an area. Implementations: bundled/cached databases,
/// on-demand downloads (OpenStreetMap via Overpass), in-memory test data.
public protocol BuildingSource: Sendable {
    /// All buildings whose footprint may intersect `rect` (world coordinates).
    func buildings(in rect: WorldRect) async throws -> [Building]
    /// Buildings of `rect` tile by tile as far as data can be obtained (downloading
    /// if possible), with the version of every data tile covering `rect`.
    func coverage(in rect: WorldRect) async -> BuildingCoverage
    /// The current versions of data tiles. With `fetchingMissing`, tries to obtain
    /// data for tiles that have none (e.g. download when back online).
    func dataVersions(of tiles: [TileKey], fetchingMissing: Bool) async -> DataVersions
}

public extension BuildingSource {
    /// Sources without versioning: all data is version "static", or missing if loading fails.
    func coverage(in rect: WorldRect) async -> BuildingCoverage {
        let tiles = Array(TileRange(covering: rect, zoom: DataGrid.zoom))
        guard let buildings = try? await buildings(in: rect) else {
            return BuildingCoverage(buildings: [], versions: Dictionary(uniqueKeysWithValues: tiles.map { ($0, DataGrid.noData) }))
        }
        return BuildingCoverage(buildings: buildings, versions: Dictionary(uniqueKeysWithValues: tiles.map { ($0, "static") }))
    }

    func dataVersions(of tiles: [TileKey], fetchingMissing: Bool) async -> DataVersions {
        Dictionary(uniqueKeysWithValues: tiles.map { ($0, "static") })
    }
}

public enum BuildingSourceError: Error, Equatable {
    /// Building data for the area is not available (e.g. offline and not cached).
    case unavailable(String)
}

/// A fixed set of buildings, indexed by storage tile.
public struct InMemoryBuildingSource: BuildingSource {
    public let buildings: [Building]
    /// Data tiles with data (`nil`: everywhere).
    public let coveredTiles: Set<TileKey>?
    public let version: String
    private let index: [TileKey: [Int]]

    /// - Parameters:
    ///   - coveredTiles: data tiles (zoom `DataGrid.zoom`) for which data exists; `nil` means everywhere.
    ///   - version: the version reported for covered data tiles.
    public init(_ buildings: [Building], coveredTiles: Set<TileKey>? = nil, version: String = "memory") {
        self.buildings = buildings
        self.coveredTiles = coveredTiles
        self.version = version
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

    public func coverage(in rect: WorldRect) -> BuildingCoverage {
        let versions = dataVersions(of: Array(TileRange(covering: rect, zoom: DataGrid.zoom)), fetchingMissing: false)
        let covered = Set(versions.filter { $0.value != DataGrid.noData }.keys)
        // Buildings belong to the data tile containing their bounds centre.
        let available = buildings(in: rect).filter {
            covered.contains(TileKey(containing: $0.bounds.center, zoom: DataGrid.zoom))
        }
        return BuildingCoverage(buildings: available, versions: versions)
    }

    public func dataVersions(of tiles: [TileKey], fetchingMissing: Bool) -> DataVersions {
        Dictionary(uniqueKeysWithValues: tiles.map { tile in
            (tile, coveredTiles.map { $0.contains(tile) } ?? true ? version : DataGrid.noData)
        })
    }
}

/// Ground elevation (metres above mean sea level).
public protocol TerrainModel: Sendable {
    /// Identifies the terrain data; part of the line-of-sight layer ID, because
    /// different terrain gives different viewsheds.
    var identifier: String { get }
    /// Whether the ground has the same elevation everywhere (enables the exact flat-ground sweep).
    var isFlat: Bool { get }
    func elevation(at point: WorldPoint) -> Double
    /// Whether the model knows the ground at `point`. Where it does not, altitudes
    /// cannot be judged and positions count as street level.
    func hasData(at point: WorldPoint) -> Bool
}

public extension TerrainModel {
    func hasData(at point: WorldPoint) -> Bool { true }
}

/// Flat ground at a constant elevation (Berlin's Spree valley lies ≈ 34 m above sea level).
public struct FlatTerrain: TerrainModel {
    public var elevation: Double

    public init(elevation: Double) { self.elevation = elevation }

    public var identifier: String { "flat\(Int(elevation.rounded()))" }
    public var isFlat: Bool { true }

    public func elevation(at point: WorldPoint) -> Double { elevation }

    /// Typical ground elevation of central Berlin.
    public static let berlin = FlatTerrain(elevation: 35)
}

/// Several elevation models (e.g. one per city): the first one with data at a
/// position answers; elsewhere `fallback` applies and `hasData` is false.
public struct CompositeTerrain: TerrainModel {
    public let grids: [GridTerrain]
    public let fallback: Double

    public init(_ grids: [GridTerrain], fallback: Double) {
        self.grids = grids
        self.fallback = fallback
    }

    /// The identifiers of the grids (one grid: its own identifier, so layers stay the same).
    public var identifier: String { grids.map(\.identifier).joined(separator: "+") }
    public var isFlat: Bool { false }

    public func elevation(at point: WorldPoint) -> Double {
        let c = WebMercator.unproject(point)
        for grid in grids where grid.covers(latitude: c.latitude, longitude: c.longitude) {
            return grid.elevation(latitude: c.latitude, longitude: c.longitude)
        }
        return fallback
    }

    public func hasData(at point: WorldPoint) -> Bool {
        let c = WebMercator.unproject(point)
        return grids.contains { $0.covers(latitude: c.latitude, longitude: c.longitude) }
    }
}

/// A digital elevation model on a regular latitude/longitude grid, sampled bilinearly.
///
/// File format (little-endian), written by Tools/berlin/prepare_terrain.py:
/// `"MQDEM001"`, 4 × float64 (south, west, latitude step, longitude step),
/// 2 × int32 (rows, columns), rows × columns × int16 decimetres
/// (row 0 = south, column 0 = west, −32768 = no data).
public struct GridTerrain: TerrainModel {
    public enum FormatError: Error, Equatable {
        case badMagic
        case truncated
    }

    public let identifier: String
    public let south: Double
    public let west: Double
    public let latitudeStep: Double
    public let longitudeStep: Double
    public let rows: Int
    public let columns: Int
    /// Elevation used outside the grid and where it has no data.
    public let fallback: Double
    private let decimetres: [Int16]

    public static let noData = Int16.min

    public init(identifier: String, south: Double, west: Double, latitudeStep: Double, longitudeStep: Double,
                rows: Int, columns: Int, decimetres: [Int16], fallback: Double) {
        precondition(decimetres.count == rows * columns, "grid size mismatch")
        self.identifier = identifier
        self.south = south
        self.west = west
        self.latitudeStep = latitudeStep
        self.longitudeStep = longitudeStep
        self.rows = rows
        self.columns = columns
        self.decimetres = decimetres
        self.fallback = fallback
    }

    public init(identifier: String, data: Data, fallback: Double) throws {
        guard data.count >= 48, data.prefix(8) == Data("MQDEM001".utf8) else { throw FormatError.badMagic }
        func double(_ offset: Int) -> Double {
            Double(bitPattern: data.subdata(in: offset..<offset + 8).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) })
        }
        func int32(_ offset: Int) -> Int {
            Int(Int32(bitPattern: data.subdata(in: offset..<offset + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }))
        }
        let rows = int32(40), columns = int32(44)
        guard rows > 0, columns > 0, data.count >= 48 + rows * columns * 2 else { throw FormatError.truncated }
        var values = [Int16](repeating: 0, count: rows * columns)
        values.withUnsafeMutableBytes { target in
            data.copyBytes(to: target.bindMemory(to: UInt8.self), from: 48..<48 + rows * columns * 2)
        }
        for i in values.indices { values[i] = Int16(littleEndian: values[i]) }
        self.init(identifier: identifier, south: double(8), west: double(16), latitudeStep: double(24), longitudeStep: double(32),
                  rows: rows, columns: columns, decimetres: values, fallback: fallback)
    }

    public var isFlat: Bool { false }

    public func elevation(at point: WorldPoint) -> Double {
        let c = WebMercator.unproject(point)
        return elevation(latitude: c.latitude, longitude: c.longitude)
    }

    public func hasData(at point: WorldPoint) -> Bool {
        let c = WebMercator.unproject(point)
        return covers(latitude: c.latitude, longitude: c.longitude)
    }

    /// Whether the grid has data around a position.
    public func covers(latitude: Double, longitude: Double) -> Bool {
        let fy = (latitude - south) / latitudeStep
        let fx = (longitude - west) / longitudeStep
        guard fx >= 0, fy >= 0, fx <= Double(columns - 1), fy <= Double(rows - 1) else { return false }
        let x = min(Int(fx.rounded()), columns - 1), y = min(Int(fy.rounded()), rows - 1)
        return decimetres[y * columns + x] != Self.noData
    }

    public func elevation(latitude: Double, longitude: Double) -> Double {
        let fy = (latitude - south) / latitudeStep
        let fx = (longitude - west) / longitudeStep
        guard fx >= 0, fy >= 0, fx <= Double(columns - 1), fy <= Double(rows - 1) else { return fallback }
        let x0 = min(Int(fx), columns - 2), y0 = min(Int(fy), rows - 2)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        var sum = 0.0, weight = 0.0
        for (dy, wy) in [(0, 1 - ty), (1, ty)] {
            for (dx, wx) in [(0, 1 - tx), (1, tx)] {
                let v = decimetres[(y0 + dy) * columns + x0 + dx]
                let w = wx * wy
                if v != Self.noData, w > 0 {
                    sum += Double(v) / 10 * w
                    weight += w
                }
            }
        }
        return weight > 0 ? sum / weight : fallback
    }
}
