import Foundation

/// One stored position fix: a 3D location (latitude, longitude, altitude) with
/// its accuracy and the time it was recorded.
///
/// Samples are the *source of truth* of MapQuest. Everything else – in
/// particular the discovered area – is derived from them and can be rebuilt.
/// Only fixes that reveal new parts of the map are stored (novelty-driven
/// sampling, see docs/01-literature-review.md, §2.2).
public struct LocationSample: Hashable, Codable, Sendable, Identifiable {
    /// Client-generated identifier, so samples can be created offline and merged
    /// into any store (local or remote) without coordination.
    public var id: UUID
    /// WGS84 latitude in degrees.
    public var latitude: Double
    /// WGS84 longitude in degrees.
    public var longitude: Double
    /// Altitude in metres above mean sea level (Core Location's `altitude`).
    public var altitude: Double
    /// Horizontal accuracy (1σ radius) in metres. Negative values mean the position is invalid.
    public var horizontalAccuracy: Double
    /// Vertical accuracy in metres. Negative values mean the altitude is invalid.
    public var verticalAccuracy: Double
    /// When the fix was taken.
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double = 5,
        verticalAccuracy: Double = -1,
        timestamp: Date
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.timestamp = timestamp
    }

    public init(
        id: UUID = UUID(),
        coordinate: GeoCoordinate,
        altitude: Double,
        horizontalAccuracy: Double = 5,
        verticalAccuracy: Double = -1,
        timestamp: Date
    ) {
        self.init(
            id: id, latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy, timestamp: timestamp
        )
    }

    public var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }

    /// The position in integer world coordinates.
    public var worldPoint: WorldPoint { WebMercator.project(coordinate) }

    /// The storage-grid tile the sample belongs to (its spatial index key).
    public var tile: TileKey { TileKey(containing: worldPoint, zoom: DiscoveryGrid.zoom) }

    /// Whether the horizontal position is usable.
    public var hasValidPosition: Bool { horizontalAccuracy >= 0 && coordinate.isValid }

    /// Whether `altitude` carries information.
    public var hasValidAltitude: Bool { verticalAccuracy >= 0 && altitude.isFinite }
}
