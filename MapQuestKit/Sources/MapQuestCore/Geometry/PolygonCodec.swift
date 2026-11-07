import Foundation

/// Compact binary encoding of polygon rings: zig-zag encoded coordinate deltas
/// stored as LEB128 variable-length integers (the scheme used by Mapbox Vector
/// Tiles and TWKB).
///
/// Layout (version 1):
/// ```
/// u8      version (= 1)
/// varint  ring count
/// for each ring:
///   varint  point count
///   for each point: zigzag-varint dx, zigzag-varint dy
/// ```
/// Deltas are relative to the previous point; the first point of the *first*
/// ring is relative to the `origin` passed to `encode`/`decode` (e.g. the tile
/// origin), and the first point of every later ring is relative to the last
/// point of the previous ring. Tile-local geometry therefore needs about
/// 2–3 bytes per vertex.
public enum PolygonCodec {
    public static let version: UInt8 = 1

    public enum DecodingError: Error, Equatable {
        case unsupportedVersion(UInt8)
        case truncated
        case malformed
    }

    // MARK: Rings

    public static func encode(rings: [[WorldPoint]], origin: WorldPoint = .zero) -> Data {
        var bytes: [UInt8] = [version]
        bytes.reserveCapacity(8 + rings.reduce(0) { $0 + $1.count } * 4)
        writeVarint(UInt64(rings.count), to: &bytes)
        var previous = origin
        for ring in rings {
            writeVarint(UInt64(ring.count), to: &bytes)
            for point in ring {
                writeVarint(zigzag(point.x &- previous.x), to: &bytes)
                writeVarint(zigzag(point.y &- previous.y), to: &bytes)
                previous = point
            }
        }
        return Data(bytes)
    }

    public static func decodeRings(_ data: Data, origin: WorldPoint = .zero) throws -> [[WorldPoint]] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [[WorldPoint]] in
            let buffer = raw.bindMemory(to: UInt8.self)
            var offset = 0
            guard offset < buffer.count else { throw DecodingError.truncated }
            let v = buffer[offset]
            offset += 1
            guard v == version else { throw DecodingError.unsupportedVersion(v) }
            let ringCount = try readVarint(buffer, &offset)
            // Every ring needs at least one byte; reject absurd counts before allocating.
            guard ringCount <= UInt64(buffer.count) else { throw DecodingError.malformed }
            var rings: [[WorldPoint]] = []
            rings.reserveCapacity(Int(ringCount))
            var previous = origin
            for _ in 0..<ringCount {
                let pointCount = try readVarint(buffer, &offset)
                guard pointCount <= UInt64(buffer.count) else { throw DecodingError.malformed }
                var ring: [WorldPoint] = []
                ring.reserveCapacity(Int(pointCount))
                for _ in 0..<pointCount {
                    let dx = try unzigzag(readVarint(buffer, &offset))
                    let dy = try unzigzag(readVarint(buffer, &offset))
                    let point = WorldPoint(x: previous.x &+ dx, y: previous.y &+ dy)
                    ring.append(point)
                    previous = point
                }
                rings.append(ring)
            }
            return rings
        }
    }

    // MARK: Polygons

    /// Encodes a polygon as rings (exterior first).
    public static func encode(_ polygon: WorldPolygon, origin: WorldPoint = .zero) -> Data {
        encode(rings: polygon.rings, origin: origin)
    }

    public static func decodePolygon(_ data: Data, origin: WorldPoint = .zero) throws -> WorldPolygon {
        let rings = try decodeRings(data, origin: origin)
        guard let exterior = rings.first else { throw DecodingError.malformed }
        return WorldPolygon(exterior: exterior, holes: Array(rings.dropFirst()))
    }

    // MARK: Primitives

    @inline(__always)
    static func zigzag(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }

    @inline(__always)
    static func unzigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }

    @inline(__always)
    static func writeVarint(_ value: UInt64, to bytes: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    @inline(__always)
    static func readVarint(_ buffer: UnsafeBufferPointer<UInt8>, _ offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < buffer.count else { throw DecodingError.truncated }
            let byte = buffer[offset]
            offset += 1
            guard shift < 64 else { throw DecodingError.malformed }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }
}
