import Foundation

/// A point in integer *world coordinates*: Web Mercator (EPSG:3857) scaled to a
/// `2^32 × 2^32` square. `(0, 0)` is the north-west corner (85.05°N, 180°W),
/// x grows eastwards and y grows southwards – the same orientation as
/// slippy-map tiles and MapKit's `MKMapPoint` (which uses a `2^28` world).
///
/// One unit is 9.3 mm at the equator and 5.7 mm in Berlin. All discovered-area
/// geometry is stored and processed in these integer coordinates, which makes
/// polygon Boolean operations robust (see docs/01-literature-review.md, §3.2).
public struct WorldPoint: Hashable, Codable, Sendable {
    public var x: Int64
    public var y: Int64

    public init(x: Int64, y: Int64) {
        self.x = x
        self.y = y
    }

    public static let zero = WorldPoint(x: 0, y: 0)
}

/// An axis-aligned rectangle in world coordinates. `max` values are exclusive
/// for tiles but the type itself treats them as inclusive bounds of geometry.
public struct WorldRect: Hashable, Codable, Sendable {
    public var minX: Int64
    public var minY: Int64
    public var maxX: Int64
    public var maxY: Int64

    public init(minX: Int64, minY: Int64, maxX: Int64, maxY: Int64) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// The bounding rectangle of `points`, or `nil` if there are none.
    public init?<S: Sequence>(bounding points: S) where S.Element == WorldPoint {
        var iterator = points.makeIterator()
        guard let first = iterator.next() else { return nil }
        var rect = WorldRect(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        while let p = iterator.next() {
            if p.x < rect.minX { rect.minX = p.x }
            if p.x > rect.maxX { rect.maxX = p.x }
            if p.y < rect.minY { rect.minY = p.y }
            if p.y > rect.maxY { rect.maxY = p.y }
        }
        self = rect
    }

    public var width: Int64 { maxX - minX }
    public var height: Int64 { maxY - minY }
    public var center: WorldPoint { WorldPoint(x: minX + width / 2, y: minY + height / 2) }
    public var isEmpty: Bool { maxX < minX || maxY < minY }

    public func contains(_ p: WorldPoint) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    public func contains(_ other: WorldRect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    public func intersects(_ other: WorldRect) -> Bool {
        minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY
    }

    public func union(_ other: WorldRect) -> WorldRect {
        WorldRect(
            minX: min(minX, other.minX), minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY)
        )
    }

    /// The rectangle grown by `amount` units on every side (shrunk for negative values).
    public func insetBy(_ amount: Int64) -> WorldRect {
        WorldRect(minX: minX + amount, minY: minY + amount, maxX: maxX - amount, maxY: maxY - amount)
    }

    public func expanded(by amount: Int64) -> WorldRect {
        insetBy(-amount)
    }

    /// The four corners in ring order.
    public var corners: [WorldPoint] {
        [
            WorldPoint(x: minX, y: minY), WorldPoint(x: maxX, y: minY),
            WorldPoint(x: maxX, y: maxY), WorldPoint(x: minX, y: maxY),
        ]
    }
}

/// Conversions between WGS84 coordinates and integer world coordinates.
public enum WebMercator {
    /// log2 of the world size in units.
    public static let worldSizeExponent = 32
    /// Width and height of the world square in units (`2^32`).
    public static let worldSize: Int64 = 1 << 32
    /// Equatorial circumference of the WGS84 ellipsoid in metres (2π · 6 378 137 m).
    public static let earthCircumference: Double = 40_075_016.685_578_49
    /// The latitude at which the Web Mercator square ends.
    public static let maxLatitude: Double = 85.051_128_779_806_6

    /// Projects a coordinate to fractional world coordinates.
    public static func projectExact(_ coordinate: GeoCoordinate) -> (x: Double, y: Double) {
        let size = Double(worldSize)
        let lat = min(max(coordinate.latitude, -maxLatitude), maxLatitude) * .pi / 180
        let x = (coordinate.longitude + 180) / 360 * size
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * size
        return (x, y)
    }

    /// Projects a coordinate to (rounded) integer world coordinates.
    public static func project(_ coordinate: GeoCoordinate) -> WorldPoint {
        let (x, y) = projectExact(coordinate)
        let maxValue = Double(worldSize - 1)
        return WorldPoint(
            x: Int64(min(max(x.rounded(), 0), maxValue)),
            y: Int64(min(max(y.rounded(), 0), maxValue))
        )
    }

    /// Converts fractional world coordinates back to a coordinate.
    public static func unproject(x: Double, y: Double) -> GeoCoordinate {
        let size = Double(worldSize)
        let longitude = x / size * 360 - 180
        let n = Double.pi * (1 - 2 * y / size)
        let latitude = atan(sinh(n)) * 180 / .pi
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    public static func unproject(_ point: WorldPoint) -> GeoCoordinate {
        unproject(x: Double(point.x), y: Double(point.y))
    }

    /// Ground metres per world unit at a latitude (the Mercator scale factor is 1/cos φ).
    public static func metersPerUnit(atLatitude latitude: Double) -> Double {
        earthCircumference / Double(worldSize) * cos(latitude * .pi / 180)
    }

    /// Ground metres per world unit at a world y coordinate.
    public static func metersPerUnit(atWorldY y: Double) -> Double {
        metersPerUnit(atLatitude: unproject(x: 0, y: y).latitude)
    }

    /// The world rectangle covering a geographic bounding box.
    public static func worldRect(for box: GeoBoundingBox) -> WorldRect {
        let nw = project(GeoCoordinate(latitude: box.maxLatitude, longitude: box.minLongitude))
        let se = project(GeoCoordinate(latitude: box.minLatitude, longitude: box.maxLongitude))
        return WorldRect(minX: nw.x, minY: nw.y, maxX: se.x, maxY: se.y)
    }

    /// The geographic bounding box of a world rectangle.
    public static func boundingBox(for rect: WorldRect) -> GeoBoundingBox {
        let nw = unproject(WorldPoint(x: rect.minX, y: rect.minY))
        let se = unproject(WorldPoint(x: rect.maxX, y: rect.maxY))
        return GeoBoundingBox(
            minLatitude: se.latitude, minLongitude: nw.longitude,
            maxLatitude: nw.latitude, maxLongitude: se.longitude
        )
    }
}
