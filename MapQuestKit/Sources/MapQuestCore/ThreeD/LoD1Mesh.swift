import Foundation

/// A triangle mesh in a local metric frame, ready for a 3D renderer:
/// x = east, y = up, z = south (metres from `origin`). Every vertex carries a
/// normal and an RGBA colour; triangles are counter-clockwise seen from outside.
public struct Mesh: Sendable {
    public var positions: [Float] = []   // x, y, z per vertex
    public var normals: [Float] = []     // x, y, z per vertex
    public var colors: [Float] = []      // r, g, b, a per vertex
    public var indices: [UInt32] = []    // three per triangle

    public init() {}

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }

    mutating func addVertex(_ x: Float, _ y: Float, _ z: Float, normal n: (Float, Float, Float), color c: RGBA) -> UInt32 {
        let index = UInt32(vertexCount)
        positions += [x, y, z]
        normals += [n.0, n.1, n.2]
        colors += [c.r, c.g, c.b, c.a]
        return index
    }
}

public struct RGBA: Hashable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float

    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    func scaled(_ f: Float) -> RGBA { RGBA(min(r * f, 1), min(g * f, 1), min(b * f, 1), a) }
}

/// Converts between world coordinates and a local metric frame for 3D rendering.
public struct LocalFrame: Sendable {
    public let origin: WorldPoint
    public let metersPerUnit: Double

    public init(origin: WorldPoint) {
        self.origin = origin
        metersPerUnit = WebMercator.metersPerUnit(atWorldY: Double(origin.y))
    }

    /// (east, south) metres.
    public func local(_ p: WorldPoint) -> (x: Double, z: Double) {
        (Double(p.x - origin.x) * metersPerUnit, Double(p.y - origin.y) * metersPerUnit)
    }

    public func world(x: Double, z: Double) -> WorldPoint {
        WorldPoint(x: origin.x + Int64((x / metersPerUnit).rounded()), y: origin.y + Int64((z / metersPerUnit).rounded()))
    }

    /// The world rectangle of a square of `halfSize` metres around the origin.
    public func worldRect(halfSize: Double) -> WorldRect {
        let r = Int64((halfSize / metersPerUnit).rounded(.up))
        return WorldRect(minX: origin.x - r, minY: origin.y - r, maxX: origin.x + r, maxY: origin.y + r)
    }
}

/// Extrudes LoD1 buildings into a mesh, coloured by discovery state.
public enum LoD1MeshBuilder {
    public struct Style: Sendable {
        public var discovered: RGBA
        public var undiscovered: RGBA
        /// Roofs are drawn slightly brighter than walls.
        public var roofBrightness: Float

        public init(
            discovered: RGBA = RGBA(0.93, 0.86, 0.74),
            undiscovered: RGBA = RGBA(0.20, 0.22, 0.29),
            roofBrightness: Float = 1.12
        ) {
            self.discovered = discovered
            self.undiscovered = undiscovered
            self.roofBrightness = roofBrightness
        }
    }

    /// A point that is guaranteed to lie inside the footprint (centroid of its
    /// largest triangle), used to test whether a building has been discovered.
    public static func interiorPoint(of building: Building) -> WorldPoint {
        if let triangles = PolygonOps.triangulate(building.footprint),
           let largest = triangles.max(by: { abs(WorldPolygon.signedArea(of: $0)) < abs(WorldPolygon.signedArea(of: $1)) }),
           largest.count == 3 {
            return WorldPoint(
                x: (largest[0].x + largest[1].x + largest[2].x) / 3,
                y: (largest[0].y + largest[1].y + largest[2].y) / 3
            )
        }
        return building.bounds.center
    }

    /// Builds walls and roofs of all buildings.
    /// - Parameter isDiscovered: decides the colour of each building.
    public static func mesh(
        for buildings: [Building],
        frame: LocalFrame,
        style: Style = Style(),
        isDiscovered: (Building) -> Bool
    ) -> Mesh {
        var mesh = Mesh()
        for building in buildings {
            let color = isDiscovered(building) ? style.discovered : style.undiscovered
            addBuilding(building, frame: frame, color: color, roofColor: color.scaled(style.roofBrightness), to: &mesh)
        }
        return mesh
    }

    static func addBuilding(_ building: Building, frame: LocalFrame, color: RGBA, roofColor: RGBA, to mesh: inout Mesh) {
        let bottom = Float(building.minHeight)
        let top = Float(building.height)
        guard top > bottom else { return }

        // Walls. Exteriors are made counter-clockwise seen from above, holes clockwise,
        // so that (−dz, dx) is the outward normal of every edge.
        for (ringIndex, ring) in building.footprint.rings.enumerated() where ring.count >= 3 {
            var points = ring.map { frame.local($0) }
            // Seen from above (x right, −z up), counter-clockwise means a negative x/z shoelace sum.
            let area = shoelace(points)
            let wantsCounterClockwise = ringIndex == 0
            if (area < 0) != wantsCounterClockwise { points.reverse() }
            for i in 0..<points.count {
                let p = points[i]
                let q = points[(i + 1) % points.count]
                let dx = q.x - p.x, dz = q.z - p.z
                let length = (dx * dx + dz * dz).squareRoot()
                guard length > 0.01 else { continue }
                let n = (Float(-dz / length), Float(0), Float(dx / length))
                let p0 = mesh.addVertex(Float(p.x), bottom, Float(p.z), normal: n, color: color)
                let q0 = mesh.addVertex(Float(q.x), bottom, Float(q.z), normal: n, color: color)
                let q1 = mesh.addVertex(Float(q.x), top, Float(q.z), normal: n, color: color)
                let p1 = mesh.addVertex(Float(p.x), top, Float(p.z), normal: n, color: color)
                mesh.indices += [p0, q0, q1, p0, q1, p1]
            }
        }

        // Roof (and the underside of raised buildings).
        guard let triangles = PolygonOps.triangulate(building.footprint) else { return }
        for triangle in triangles where triangle.count == 3 {
            var corners = triangle.map { frame.local($0) }
            if shoelace(corners) > 0 { corners.reverse() } // counter-clockwise seen from above
            let up = (Float(0), Float(1), Float(0))
            let a = mesh.addVertex(Float(corners[0].x), top, Float(corners[0].z), normal: up, color: roofColor)
            let b = mesh.addVertex(Float(corners[1].x), top, Float(corners[1].z), normal: up, color: roofColor)
            let c = mesh.addVertex(Float(corners[2].x), top, Float(corners[2].z), normal: up, color: roofColor)
            mesh.indices += [a, b, c]
            if bottom > 0 {
                let down = (Float(0), Float(-1), Float(0))
                let d = mesh.addVertex(Float(corners[0].x), bottom, Float(corners[0].z), normal: down, color: color)
                let e = mesh.addVertex(Float(corners[1].x), bottom, Float(corners[1].z), normal: down, color: color)
                let f = mesh.addVertex(Float(corners[2].x), bottom, Float(corners[2].z), normal: down, color: color)
                mesh.indices += [d, f, e]
            }
        }
    }

    /// Shoelace sum in the x/z plane (sign only matters).
    static func shoelace(_ points: [(x: Double, z: Double)]) -> Double {
        var sum = 0.0
        for i in 0..<points.count {
            let p = points[i], q = points[(i + 1) % points.count]
            sum += p.x * q.z - q.x * p.z
        }
        return sum
    }
}
