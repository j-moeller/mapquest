import Foundation

/// A WGS84 latitude/longitude pair in degrees.
public struct GeoCoordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Mean earth radius in metres (IUGG), used for great-circle distances.
    public static let meanEarthRadius: Double = 6_371_008.8

    /// Great-circle distance in metres (haversine formula).
    public func distance(to other: GeoCoordinate) -> Double {
        let phi1 = latitude * .pi / 180
        let phi2 = other.latitude * .pi / 180
        let dPhi = (other.latitude - latitude) * .pi / 180
        let dLambda = (other.longitude - longitude) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * Self.meanEarthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Whether the coordinate is a finite, valid WGS84 position.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// An axis-aligned latitude/longitude box. Boxes crossing the antimeridian are not supported.
public struct GeoBoundingBox: Hashable, Codable, Sendable {
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double

    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
    }

    /// The smallest box containing all `coordinates`, or `nil` for an empty sequence.
    public init?<S: Sequence>(containing coordinates: S) where S.Element == GeoCoordinate {
        var iterator = coordinates.makeIterator()
        guard let first = iterator.next() else { return nil }
        var box = GeoBoundingBox(
            minLatitude: first.latitude, minLongitude: first.longitude,
            maxLatitude: first.latitude, maxLongitude: first.longitude
        )
        while let c = iterator.next() {
            box.minLatitude = min(box.minLatitude, c.latitude)
            box.maxLatitude = max(box.maxLatitude, c.latitude)
            box.minLongitude = min(box.minLongitude, c.longitude)
            box.maxLongitude = max(box.maxLongitude, c.longitude)
        }
        self = box
    }

    /// A box of `radius` metres around `center` (approximation valid away from the poles).
    public init(center: GeoCoordinate, radius: Double) {
        let dLat = radius / 111_320.0
        let dLon = radius / (111_320.0 * max(cos(center.latitude * .pi / 180), 1e-6))
        self.init(
            minLatitude: center.latitude - dLat, minLongitude: center.longitude - dLon,
            maxLatitude: center.latitude + dLat, maxLongitude: center.longitude + dLon
        )
    }

    public var center: GeoCoordinate {
        GeoCoordinate(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
    }

    public func contains(_ coordinate: GeoCoordinate) -> Bool {
        coordinate.latitude >= minLatitude && coordinate.latitude <= maxLatitude
            && coordinate.longitude >= minLongitude && coordinate.longitude <= maxLongitude
    }

    public func intersects(_ other: GeoBoundingBox) -> Bool {
        minLatitude <= other.maxLatitude && maxLatitude >= other.minLatitude
            && minLongitude <= other.maxLongitude && maxLongitude >= other.minLongitude
    }

    public func union(_ other: GeoBoundingBox) -> GeoBoundingBox {
        GeoBoundingBox(
            minLatitude: min(minLatitude, other.minLatitude),
            minLongitude: min(minLongitude, other.minLongitude),
            maxLatitude: max(maxLatitude, other.maxLatitude),
            maxLongitude: max(maxLongitude, other.maxLongitude)
        )
    }

    /// The box grown by `meters` on every side.
    public func expanded(byMeters meters: Double) -> GeoBoundingBox {
        let dLat = meters / 111_320.0
        let dLon = meters / (111_320.0 * max(cos(center.latitude * .pi / 180), 1e-6))
        return GeoBoundingBox(
            minLatitude: max(minLatitude - dLat, -90), minLongitude: max(minLongitude - dLon, -180),
            maxLatitude: min(maxLatitude + dLat, 90), maxLongitude: min(maxLongitude + dLon, 180)
        )
    }
}
