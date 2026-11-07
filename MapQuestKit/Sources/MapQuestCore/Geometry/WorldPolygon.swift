import Foundation

/// A closed ring of world points. The closing edge from the last point back to
/// the first is implicit (the first point is not repeated).
public typealias WorldRing = [WorldPoint]

/// A polygon with holes in world coordinates: one exterior ring and any number of hole rings.
///
/// Ring orientation is not significant for the stored model; rendering uses the
/// even-odd/non-zero rule on exterior and holes, which yields the same result
/// for valid polygons (holes inside the exterior, rings not intersecting).
public struct WorldPolygon: Hashable, Codable, Sendable {
    public var exterior: WorldRing
    public var holes: [WorldRing]

    public init(exterior: WorldRing, holes: [WorldRing] = []) {
        self.exterior = exterior
        self.holes = holes
    }

    /// Exterior followed by holes.
    public var rings: [WorldRing] { [exterior] + holes }

    public var bounds: WorldRect {
        WorldRect(bounding: exterior) ?? WorldRect(minX: 0, minY: 0, maxX: -1, maxY: -1)
    }

    public var vertexCount: Int { exterior.count + holes.reduce(0) { $0 + $1.count } }

    /// Area in square world units (exterior minus holes).
    public var area: Double {
        abs(Self.signedArea(of: exterior)) - holes.reduce(0) { $0 + abs(Self.signedArea(of: $1)) }
    }

    /// Area in square metres, using the scale at the polygon's centre latitude.
    public var areaSquareMeters: Double {
        let mpu = WebMercator.metersPerUnit(atWorldY: Double(bounds.center.y))
        return area * mpu * mpu
    }

    /// Whether the point lies inside the exterior and outside all holes.
    /// Points exactly on the boundary may be reported either way.
    public func contains(_ point: WorldPoint) -> Bool {
        guard bounds.contains(point), Self.ring(exterior, contains: point) else { return false }
        return !holes.contains { Self.ring($0, contains: point) }
    }

    /// Signed shoelace area of a ring in square world units. Positive for rings that
    /// are counter-clockwise in a y-up frame (clockwise on a y-down map).
    public static func signedArea(of ring: WorldRing) -> Double {
        guard ring.count >= 3 else { return 0 }
        // Work relative to the first vertex to keep products small and exact.
        let ox = ring[0].x
        let oy = ring[0].y
        var sum: Double = 0
        var previous = ring[ring.count - 1]
        for current in ring {
            let x1 = Double(previous.x - ox), y1 = Double(previous.y - oy)
            let x2 = Double(current.x - ox), y2 = Double(current.y - oy)
            sum += x1 * y2 - x2 * y1
            previous = current
        }
        return sum / 2
    }

    /// Crossing-number point-in-ring test.
    public static func ring(_ ring: WorldRing, contains point: WorldPoint) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i]
            let b = ring[j]
            if (a.y > point.y) != (b.y > point.y) {
                // x coordinate of the edge at point.y, computed in Double relative to a.
                let t = Double(point.y - a.y) / Double(b.y - a.y)
                let xCross = Double(a.x) + t * Double(b.x - a.x)
                if Double(point.x) < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

public extension Array where Element == WorldPolygon {
    var bounds: WorldRect? {
        guard let first else { return nil }
        return dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    var areaSquareMeters: Double { reduce(0) { $0 + $1.areaSquareMeters } }
}
