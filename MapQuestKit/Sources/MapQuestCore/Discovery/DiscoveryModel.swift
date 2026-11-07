import Foundation

/// Decides which area a single location sample reveals.
///
/// Every model writes its own layer of discovered area. The 2D model reveals a
/// circle; the 3D model reveals what is visible between the buildings.
public protocol DiscoveryModel: Sendable {
    /// The layer this model's results are stored in. Must change whenever the
    /// model's parameters change in a way that changes results.
    var layer: DiscoveryLayerID { get }

    /// The area revealed by `sample`, in world coordinates. May consist of
    /// several disconnected polygons.
    func revealedArea(for sample: LocationSample) async throws -> [WorldPolygon]
}

/// The 2D discovery model: everything within `radius` metres of a sample is revealed.
public struct CircleDiscoveryModel: DiscoveryModel {
    /// Radius in metres.
    public var radius: Double
    /// Number of vertices of the circle polygon (64 → max. 6 cm error at 50 m).
    public var segments: Int

    public init(radius: Double = 50, segments: Int = 64) {
        precondition(radius > 0, "radius must be positive")
        self.radius = radius
        self.segments = segments
    }

    public var layer: DiscoveryLayerID { DiscoveryLayerID("circle-\(Int(radius.rounded()))m") }

    public func revealedArea(for sample: LocationSample) -> [WorldPolygon] {
        [circle(around: sample.coordinate)]
    }

    public func circle(around coordinate: GeoCoordinate) -> WorldPolygon {
        let center = WebMercator.project(coordinate)
        let unitsPerMeter = 1 / WebMercator.metersPerUnit(atLatitude: coordinate.latitude)
        return PolygonOps.circle(center: center, radius: radius * unitsPerMeter, segments: segments)
    }
}
