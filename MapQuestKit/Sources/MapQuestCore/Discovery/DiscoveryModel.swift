import Foundation

/// The area revealed by one sample, and the map data it was computed from.
public struct Revelation: Sendable {
    public var polygons: [WorldPolygon]
    /// The version of every data tile in the sample's data window (empty for
    /// models that use no map data).
    public var dataVersions: DataVersions

    public init(polygons: [WorldPolygon], dataVersions: DataVersions = [:]) {
        self.polygons = polygons
        self.dataVersions = dataVersions
    }
}

/// Decides which area a single location sample reveals.
///
/// Every model writes its own layer of discovered area. The 2D model reveals a
/// circle; the 3D model reveals what is visible between the buildings.
///
/// Models that use map data (buildings) declare which data a result depends
/// on, so that cached results can be refreshed when the data changes
/// (docs/05-cache-invalidation.md): the result for a sample depends only on the
/// data tiles intersecting its `dataWindow`, and lies inside that window.
public protocol DiscoveryModel: Sendable {
    /// The layer this model's results are stored in. Must change whenever the
    /// model's parameters change in a way that changes results.
    var layer: DiscoveryLayerID { get }

    /// The area revealed by `sample`, in world coordinates. May consist of
    /// several disconnected polygons.
    func revealedArea(for sample: LocationSample) async throws -> [WorldPolygon]

    /// The revealed area together with the versions of the map data used.
    func revelation(for sample: LocationSample) async throws -> Revelation

    /// The part of the map whose data can influence the result for `sample`
    /// (world coordinates); the revealed area lies inside it. `nil` for models
    /// that use no map data.
    func dataWindow(for sample: LocationSample) -> WorldRect?

    /// An upper bound (metres) for the distance from a sample to the edge of its
    /// data window; 0 for models that use no map data.
    var maximumDataReach: Double { get }

    /// The current versions of data tiles. With `fetchingMissing`, tries to obtain
    /// data where none is available (e.g. download it when back online).
    func currentDataVersions(of tiles: [TileKey], fetchingMissing: Bool) async -> DataVersions
}

public extension DiscoveryModel {
    func revelation(for sample: LocationSample) async throws -> Revelation {
        Revelation(polygons: try await revealedArea(for: sample))
    }

    func dataWindow(for sample: LocationSample) -> WorldRect? { nil }

    var maximumDataReach: Double { 0 }

    func currentDataVersions(of tiles: [TileKey], fetchingMissing: Bool) async -> DataVersions { [:] }

    /// Whether results depend on map data (and must be refreshed when it changes).
    var usesMapData: Bool { maximumDataReach > 0 }

    /// The data tiles the result for `sample` depends on.
    func dataTiles(for sample: LocationSample) -> TileRange? {
        dataWindow(for: sample).map { TileRange(covering: $0, zoom: DataGrid.zoom) }
    }
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
