import Foundation

/// A sight's 3D model: the walls and roofs of its building(s) from Berlin's LoD2
/// building models (Tools/capture/sight_models.py), in the sight's local frame –
/// x east, y up, z south, metres; the origin is the sight's position at the
/// lowest ground point of the model (like `LocalFrame`).
///
/// File format "MQM1" (little-endian; bundled raw-DEFLATE-compressed):
/// magic, uint32 vertex count, uint32 index count, uint32 footprint ring count,
/// vertices (int16 x, y, z in decimetres), one uint8 per vertex (0 wall, 1 roof),
/// uint32 triangle indices (wound counter-clockwise seen from outside), footprint
/// rings (uint32 point count, then int16 x, z in decimetres).
public struct SightModel: Sendable {
    public struct Point2: Hashable, Sendable {
        public var x: Double
        public var z: Double
    }

    public enum FormatError: Error, Equatable {
        case badMagic
        case truncated
        case badIndex
    }

    /// x, y, z per vertex.
    public var positions: [Float]
    /// Per vertex: part of a roof (else a wall).
    public var isRoof: [Bool]
    /// Three per triangle.
    public var indices: [UInt32]
    /// Ground outlines of the model's buildings.
    public var footprints: [[Point2]]

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }

    public static func decode(_ data: Data) throws -> SightModel {
        let bytes = [UInt8](data)
        var offset = 0
        func uint32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw FormatError.truncated }
            defer { offset += 4 }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        func int16() throws -> Int16 {
            guard offset + 2 <= bytes.count else { throw FormatError.truncated }
            defer { offset += 2 }
            return Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
        }
        guard bytes.count >= 16, Array(bytes[0..<4]) == Array("MQM1".utf8) else { throw FormatError.badMagic }
        offset = 4
        let vertexCount = Int(try uint32()), indexCount = Int(try uint32()), ringCount = Int(try uint32())
        guard vertexCount <= 5_000_000, indexCount <= 15_000_000, ringCount <= 100_000 else { throw FormatError.truncated }
        var positions = [Float]()
        positions.reserveCapacity(vertexCount * 3)
        for _ in 0..<(vertexCount * 3) {
            positions.append(Float(try int16()) / 10)
        }
        guard offset + vertexCount <= bytes.count else { throw FormatError.truncated }
        let isRoof = bytes[offset..<(offset + vertexCount)].map { $0 == 1 }
        offset += vertexCount
        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount {
            let index = try uint32()
            guard Int(index) < vertexCount else { throw FormatError.badIndex }
            indices.append(index)
        }
        var footprints: [[Point2]] = []
        for _ in 0..<ringCount {
            let count = Int(try uint32())
            var ring: [Point2] = []
            for _ in 0..<count {
                let x = Double(try int16()) / 10, z = Double(try int16()) / 10
                ring.append(Point2(x: x, z: z))
            }
            footprints.append(ring)
        }
        return SightModel(positions: positions, isRoof: isRoof, indices: indices, footprints: footprints)
    }

    /// Smallest and largest x, y, z.
    public var bounds: (min: (x: Float, y: Float, z: Float), max: (x: Float, y: Float, z: Float)) {
        var lo = (x: Float.infinity, y: Float.infinity, z: Float.infinity)
        var hi = (x: -Float.infinity, y: -Float.infinity, z: -Float.infinity)
        for i in 0..<vertexCount {
            lo = (min(lo.x, positions[3 * i]), min(lo.y, positions[3 * i + 1]), min(lo.z, positions[3 * i + 2]))
            hi = (max(hi.x, positions[3 * i]), max(hi.y, positions[3 * i + 1]), max(hi.z, positions[3 * i + 2]))
        }
        return (lo, hi)
    }

    /// Whether a local ground point lies inside one of the footprints (even-odd).
    public func footprintContains(x: Double, z: Double) -> Bool {
        for ring in footprints where ring.count >= 3 {
            var inside = false
            var j = ring.count - 1
            for i in 0..<ring.count {
                let a = ring[i], b = ring[j]
                if (a.z > z) != (b.z > z), x < (b.x - a.x) * (z - a.z) / (b.z - a.z) + a.x {
                    inside.toggle()
                }
                j = i
            }
            if inside { return true }
        }
        return false
    }

    /// A flat-shaded mesh (one normal per polygon: its vertices are its own) in
    /// the wall and roof colours.
    public func mesh(wall: RGBA, roof: RGBA) -> Mesh {
        var mesh = Mesh()
        mesh.positions = positions
        mesh.indices = indices
        var normals = [Float](repeating: 0, count: positions.count)
        var assigned = [Bool](repeating: false, count: vertexCount)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let ux = positions[3 * b] - positions[3 * a], uy = positions[3 * b + 1] - positions[3 * a + 1], uz = positions[3 * b + 2] - positions[3 * a + 2]
            let vx = positions[3 * c] - positions[3 * a], vy = positions[3 * c + 1] - positions[3 * a + 1], vz = positions[3 * c + 2] - positions[3 * a + 2]
            var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
            let length = (nx * nx + ny * ny + nz * nz).squareRoot()
            guard length > 1e-6 else { continue }
            nx /= length; ny /= length; nz /= length
            for v in [a, b, c] where !assigned[v] {
                assigned[v] = true
                normals[3 * v] = nx; normals[3 * v + 1] = ny; normals[3 * v + 2] = nz
            }
        }
        // Vertices of degenerate triangles only: upwards.
        for v in 0..<vertexCount where !assigned[v] {
            normals[3 * v + 1] = 1
        }
        mesh.normals = normals
        mesh.colors.reserveCapacity(vertexCount * 4)
        for roofVertex in isRoof {
            let color = roofVertex ? roof : wall
            mesh.colors += [color.r, color.g, color.b, color.a]
        }
        return mesh
    }
}
