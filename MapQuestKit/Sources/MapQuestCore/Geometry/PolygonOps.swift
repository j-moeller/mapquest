import CClipper2
import Foundation

/// Robust polygon operations on integer world coordinates, backed by Clipper2.
///
/// Inputs are interpreted with the non-zero fill rule after normalising ring
/// orientation (exteriors positive, holes negative), so the orientation of
/// `WorldPolygon` rings never matters to callers. Results are polygons with
/// explicit holes; disjoint parts are separate polygons.
public enum PolygonOps {
    // MARK: Boolean operations

    public static func union(_ polygons: [WorldPolygon]) -> [WorldPolygon] {
        boolean(.union, polygons, [])
    }

    public static func union(_ a: [WorldPolygon], _ b: [WorldPolygon]) -> [WorldPolygon] {
        boolean(.union, a, b)
    }

    public static func intersection(_ a: [WorldPolygon], _ b: [WorldPolygon]) -> [WorldPolygon] {
        guard let ba = a.bounds, let bb = b.bounds, ba.intersects(bb) else { return [] }
        return boolean(.intersection, a, b)
    }

    public static func difference(_ a: [WorldPolygon], _ b: [WorldPolygon]) -> [WorldPolygon] {
        guard !a.isEmpty else { return [] }
        guard let ba = a.bounds, let bb = b.bounds, ba.intersects(bb) else { return union(a) }
        return boolean(.difference, a, b)
    }

    /// Whether the two areas overlap with non-zero area.
    public static func intersects(_ a: [WorldPolygon], _ b: [WorldPolygon]) -> Bool {
        !intersection(a, b).isEmpty
    }

    // MARK: Offsetting, clipping, simplification

    /// Grows (positive `delta`) or shrinks (negative) polygons by `delta` world units with round joins.
    /// `arcTolerance` is the maximum deviation of approximated arcs in units (0 = Clipper default).
    public static func inflate(_ polygons: [WorldPolygon], by delta: Double, arcTolerance: Double = 0) -> [WorldPolygon] {
        guard !polygons.isEmpty else { return [] }
        return withPaths(polygons) { input in
            take(mq_inflate(input, delta, MQJoinRound, MQEndPolygon, 2.0, arcTolerance))
        }
    }

    /// The area within `radius` units of an open polyline (a "corridor" with round caps).
    public static func buffer(polyline: [WorldPoint], radius: Double, arcTolerance: Double = 0) -> [WorldPolygon] {
        guard !polyline.isEmpty, radius > 0 else { return [] }
        if polyline.count == 1 {
            return [circle(center: polyline[0], radius: radius, segments: 64)]
        }
        var coords: [Int64] = []
        coords.reserveCapacity(polyline.count * 2)
        for p in polyline {
            coords.append(p.x)
            coords.append(p.y)
        }
        let counts = [polyline.count]
        return coords.withUnsafeBufferPointer { c in
            counts.withUnsafeBufferPointer { n in
                let input = MQPathsInput(coords: c.baseAddress, counts: n.baseAddress, pathCount: 1)
                return take(mq_inflate(input, radius, MQJoinRound, MQEndRound, 2.0, arcTolerance))
            }
        }
    }

    /// Clips polygons to an axis-aligned rectangle.
    public static func clip(_ polygons: [WorldPolygon], to rect: WorldRect) -> [WorldPolygon] {
        guard let bounds = polygons.bounds, bounds.intersects(rect) else { return [] }
        if rect.contains(bounds) { return union(polygons) }
        return withPaths(polygons) { input in
            take(mq_rect_clip(input, rect.minX, rect.minY, rect.maxX, rect.maxY))
        }
    }

    /// Removes vertices that deviate less than `epsilon` units from their neighbours' line.
    public static func simplify(_ polygons: [WorldPolygon], epsilon: Double) -> [WorldPolygon] {
        guard !polygons.isEmpty, epsilon > 0 else { return polygons }
        return withPaths(polygons) { input in
            take(mq_simplify(input, epsilon))
        }
    }

    /// Triangulates a polygon with holes. Returns `nil` if the rings intersect.
    public static func triangulate(_ polygon: WorldPolygon, delaunay: Bool = true) -> [[WorldPoint]]? {
        withPaths([polygon]) { input in
            guard let result = mq_triangulate(input, delaunay ? 1 : 0) else { return nil }
            return take(result).map(\.exterior)
        }
    }

    // MARK: Shapes

    /// A regular polygon approximating a circle. `radius` is in world units.
    public static func circle(center: WorldPoint, radius: Double, segments: Int = 64) -> WorldPolygon {
        let n = max(segments, 8)
        var ring: WorldRing = []
        ring.reserveCapacity(n)
        for i in 0..<n {
            let angle = Double(i) / Double(n) * 2 * .pi
            ring.append(WorldPoint(
                x: center.x + Int64((cos(angle) * radius).rounded()),
                y: center.y + Int64((sin(angle) * radius).rounded())
            ))
        }
        return WorldPolygon(exterior: ring)
    }

    /// A rectangle as a polygon.
    public static func rectangle(_ rect: WorldRect) -> WorldPolygon {
        WorldPolygon(exterior: rect.corners)
    }

    // MARK: Bridging

    private enum Operation {
        case intersection, union, difference

        var clipType: MQClipType {
            switch self {
            case .intersection: return MQClipIntersection
            case .union: return MQClipUnion
            case .difference: return MQClipDifference
            }
        }
    }

    private static func boolean(_ operation: Operation, _ subject: [WorldPolygon], _ clip: [WorldPolygon]) -> [WorldPolygon] {
        withPaths(subject) { s in
            withPaths(clip) { c in
                take(mq_boolean(operation.clipType, MQFillNonZero, s, c))
            }
        }
    }

    /// Flattens polygons into Clipper's input layout with normalised orientation.
    private static func withPaths<R>(_ polygons: [WorldPolygon], _ body: (MQPathsInput) -> R) -> R {
        var coords: [Int64] = []
        var counts: [Int] = []
        coords.reserveCapacity(polygons.reduce(0) { $0 + $1.vertexCount } * 2)
        for polygon in polygons {
            for (index, ring) in polygon.rings.enumerated() where ring.count >= 3 {
                let area = WorldPolygon.signedArea(of: ring)
                guard area != 0 else { continue }
                let wantsPositive = index == 0
                if (area > 0) == wantsPositive {
                    for p in ring {
                        coords.append(p.x)
                        coords.append(p.y)
                    }
                } else {
                    for p in ring.reversed() {
                        coords.append(p.x)
                        coords.append(p.y)
                    }
                }
                counts.append(ring.count)
            }
        }
        return coords.withUnsafeBufferPointer { c in
            counts.withUnsafeBufferPointer { n in
                body(MQPathsInput(coords: c.baseAddress, counts: n.baseAddress, pathCount: counts.count))
            }
        }
    }

    /// Converts and frees a Clipper result.
    private static func take(_ result: OpaquePointer?) -> [WorldPolygon] {
        guard let result else { return [] }
        defer { mq_polygons_free(result) }
        let polygonCount = mq_polygons_count(result)
        var polygons: [WorldPolygon] = []
        polygons.reserveCapacity(polygonCount)
        var buffer: [Int64] = []
        for polygonIndex in 0..<polygonCount {
            let ringCount = mq_polygons_ring_count(result, polygonIndex)
            var rings: [WorldRing] = []
            rings.reserveCapacity(ringCount)
            for ringIndex in 0..<ringCount {
                let pointCount = mq_polygons_ring_point_count(result, polygonIndex, ringIndex)
                guard pointCount >= 3 else { continue }
                if buffer.count < pointCount * 2 {
                    buffer = [Int64](repeating: 0, count: pointCount * 2)
                }
                buffer.withUnsafeMutableBufferPointer { out in
                    mq_polygons_copy_ring(result, polygonIndex, ringIndex, out.baseAddress)
                }
                var ring: WorldRing = []
                ring.reserveCapacity(pointCount)
                for i in 0..<pointCount {
                    ring.append(WorldPoint(x: buffer[2 * i], y: buffer[2 * i + 1]))
                }
                rings.append(ring)
            }
            if let exterior = rings.first {
                polygons.append(WorldPolygon(exterior: exterior, holes: Array(rings.dropFirst())))
            }
        }
        return polygons
    }
}
