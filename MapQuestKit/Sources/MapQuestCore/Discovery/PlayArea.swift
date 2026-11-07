import Foundation

/// A named area of the world: the play area in which positions are recorded
/// (Berlin for now), and its subdivisions (districts) for statistics.
public struct PlayArea: Sendable {
    public var name: String
    /// Boundary polygons in world coordinates. Empty means "the whole world".
    public var polygons: [WorldPolygon]
    /// Named parts of the area (e.g. the twelve Berlin districts).
    public var subdivisions: [PlayArea]

    public init(name: String, polygons: [WorldPolygon], subdivisions: [PlayArea] = []) {
        self.name = name
        self.polygons = polygons
        self.subdivisions = subdivisions
    }

    public static let world = PlayArea(name: "World", polygons: [])

    public var isWorld: Bool { polygons.isEmpty }

    public var bounds: WorldRect? { polygons.bounds }

    public var boundingBox: GeoBoundingBox? { bounds.map(WebMercator.boundingBox(for:)) }

    public var areaSquareMeters: Double { polygons.areaSquareMeters }

    public func contains(_ coordinate: GeoCoordinate) -> Bool {
        guard !isWorld else { return true }
        let point = WebMercator.project(coordinate)
        return polygons.contains { $0.contains(point) }
    }
}

/// How much of an area has been discovered.
public struct AreaCoverage: Hashable, Sendable {
    public var name: String
    public var areaSquareMeters: Double
    public var discoveredSquareMeters: Double

    public var fraction: Double { areaSquareMeters > 0 ? min(1, discoveredSquareMeters / areaSquareMeters) : 0 }
}

public enum DiscoveryStatistics {
    /// Discovered area inside each of `areas`, computed tile by tile so that
    /// every intersection only involves small, tile-clipped polygons.
    public static func coverage(of snapshot: DiscoveredAreaSnapshot, in areas: [PlayArea]) -> [AreaCoverage] {
        let bounds = areas.map(\.bounds)
        var discovered = [Double](repeating: 0, count: areas.count)
        for (tile, pieces) in snapshot.piecesByTile where !pieces.isEmpty {
            let rect = tile.worldRect
            let candidates = areas.indices.filter { bounds[$0]?.intersects(rect) ?? false }
            guard !candidates.isEmpty else { continue }
            // The tile's discovered area without the overlap margins.
            let exact = PolygonOps.clip(pieces.map(\.polygon), to: rect)
            guard !exact.isEmpty else { continue }
            let scale = tile.metersPerUnit * tile.metersPerUnit
            for index in candidates {
                let part = PolygonOps.clip(areas[index].polygons, to: rect)
                guard !part.isEmpty else { continue }
                let inside = PolygonOps.intersection(exact, part)
                discovered[index] += inside.reduce(0) { $0 + $1.area } * scale
            }
        }
        return areas.indices.map { index in
            AreaCoverage(
                name: areas[index].name,
                areaSquareMeters: areas[index].areaSquareMeters,
                discoveredSquareMeters: discovered[index]
            )
        }
    }
}
