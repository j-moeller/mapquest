import Foundation

/// The part of the world in which positions are recorded (Berlin for now).
public struct PlayArea: Sendable {
    public var name: String
    /// Boundary polygons in world coordinates. Empty means "the whole world".
    public var polygons: [WorldPolygon]

    public init(name: String, polygons: [WorldPolygon]) {
        self.name = name
        self.polygons = polygons
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
