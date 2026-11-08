import Foundation

/// One fix of the continuous location track (recorded about once per second).
///
/// Values are stored quantized – time in 0.1 s, latitude and longitude in
/// micro-degrees (≈ 0.11 m), altitude and accuracies in decimetres – which is
/// far below GNSS accuracy and makes the delta encoding of `TrackCodec`
/// compact (≈ 6–8 bytes per fix). Encoding and decoding are exact.
public struct TrackPoint: Hashable, Sendable {
    /// Deciseconds since 1970-01-01 UTC.
    public var time: Int64
    /// Latitude in micro-degrees.
    public var latitudeE6: Int32
    /// Longitude in micro-degrees.
    public var longitudeE6: Int32
    /// Altitude above mean sea level in decimetres.
    public var altitudeDM: Int32
    /// Horizontal accuracy in decimetres (negative: invalid position).
    public var horizontalAccuracyDM: Int32
    /// Vertical accuracy in decimetres (negative: invalid altitude).
    public var verticalAccuracyDM: Int32

    public init(time: Int64, latitudeE6: Int32, longitudeE6: Int32, altitudeDM: Int32, horizontalAccuracyDM: Int32, verticalAccuracyDM: Int32) {
        self.time = time
        self.latitudeE6 = latitudeE6
        self.longitudeE6 = longitudeE6
        self.altitudeDM = altitudeDM
        self.horizontalAccuracyDM = horizontalAccuracyDM
        self.verticalAccuracyDM = verticalAccuracyDM
    }

    public init(
        timestamp: Date, latitude: Double, longitude: Double, altitude: Double,
        horizontalAccuracy: Double, verticalAccuracy: Double
    ) {
        func clamp(_ value: Double) -> Int32 {
            guard value.isFinite else { return -1 }
            return Int32(max(-2_000_000_000, min(2_000_000_000, value.rounded())))
        }
        time = Int64((timestamp.timeIntervalSince1970 * 10).rounded())
        latitudeE6 = clamp(latitude * 1e6)
        longitudeE6 = clamp(longitude * 1e6)
        altitudeDM = altitude.isFinite ? clamp(altitude * 10) : 0
        horizontalAccuracyDM = horizontalAccuracy < 0 ? -1 : clamp(horizontalAccuracy * 10)
        verticalAccuracyDM = verticalAccuracy < 0 ? -1 : clamp(verticalAccuracy * 10)
    }

    public init(_ sample: LocationSample) {
        self.init(
            timestamp: sample.timestamp, latitude: sample.latitude, longitude: sample.longitude, altitude: sample.altitude,
            horizontalAccuracy: sample.horizontalAccuracy, verticalAccuracy: sample.verticalAccuracy
        )
    }

    public var timestamp: Date { Date(timeIntervalSince1970: Double(time) / 10) }
    public var latitude: Double { Double(latitudeE6) / 1e6 }
    public var longitude: Double { Double(longitudeE6) / 1e6 }
    public var altitude: Double { Double(altitudeDM) / 10 }
    public var horizontalAccuracy: Double { horizontalAccuracyDM < 0 ? -1 : Double(horizontalAccuracyDM) / 10 }
    public var verticalAccuracy: Double { verticalAccuracyDM < 0 ? -1 : Double(verticalAccuracyDM) / 10 }
    public var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }
    public var worldPoint: WorldPoint { WebMercator.project(coordinate) }
    public var hasValidPosition: Bool { horizontalAccuracyDM >= 0 && coordinate.isValid }

    /// The fix as a location sample, with an ID derived from its time, so the same
    /// track point always yields the same sample.
    public var sample: LocationSample {
        LocationSample(
            id: Self.sampleID(time: time), latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy, timestamp: timestamp
        )
    }

    static func sampleID(time: Int64) -> UUID {
        let t = UInt64(bitPattern: time).bigEndian
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: t) { raw in for i in 0..<8 { bytes[i] = raw[i] } }
        // "MQTRACK" + 0: distinguishes track-derived samples from random (version 4) UUIDs.
        let tag: [UInt8] = [0x4D, 0x51, 0x54, 0x52, 0x41, 0x43, 0x4B, 0x00]
        for i in 0..<8 { bytes[8 + i] = tag[i] }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// A run of consecutive track points stored as one delta-encoded blob, with its
/// time span and bounding box for queries. Segments are the storage unit of the
/// track: the open segment is rewritten while it grows, closed ones never change.
public struct TrackSegment: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var start: Date
    public var end: Date
    /// Bounding box of the points (world coordinates).
    public var bounds: WorldRect
    public var pointCount: Int
    /// `TrackCodec` encoding of the points.
    public var data: Data

    public init(id: UUID, start: Date, end: Date, bounds: WorldRect, pointCount: Int, data: Data) {
        self.id = id
        self.start = start
        self.end = end
        self.bounds = bounds
        self.pointCount = pointCount
        self.data = data
    }

    /// Encodes points (in chronological order, at least one).
    public init(id: UUID = UUID(), points: [TrackPoint]) {
        precondition(!points.isEmpty, "a segment needs points")
        self.id = id
        start = points.first!.timestamp
        end = points.last!.timestamp
        bounds = WorldRect(bounding: points.map(\.worldPoint)) ?? WorldRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        pointCount = points.count
        data = TrackCodec.encode(points)
    }

    public func points() throws -> [TrackPoint] {
        try TrackCodec.decode(data)
    }
}

/// Size and extent of a stored track.
public struct TrackSummary: Hashable, Sendable {
    public var segmentCount: Int
    public var pointCount: Int
    /// Bytes of encoded point data.
    public var byteCount: Int
    public var first: Date?
    public var last: Date?

    public init(segmentCount: Int = 0, pointCount: Int = 0, byteCount: Int = 0, first: Date? = nil, last: Date? = nil) {
        self.segmentCount = segmentCount
        self.pointCount = pointCount
        self.byteCount = byteCount
        self.first = first
        self.last = last
    }

    public var bytesPerPoint: Double { pointCount > 0 ? Double(byteCount) / Double(pointCount) : 0 }
}

/// Lossless delta encoding of track points (after quantization):
///
///     byte      version (1)
///     varint    point count
///     per point: zig-zag varints of the differences to the previous point
///                (the first point: to zero) of time, latitude, longitude,
///                altitude, horizontal and vertical accuracy
///
/// At 1 Hz on foot most differences fit into one byte: ≈ 6–8 bytes per fix,
/// versus 40+ bytes for a row of doubles in SQLite.
public enum TrackCodec {
    public enum DecodingError: Error, Equatable {
        case unsupportedVersion(UInt8)
        case truncated
    }

    public static let version: UInt8 = 1

    public static func encode(_ points: [TrackPoint]) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(4 + points.count * 8)
        out.append(version)
        writeUnsigned(UInt64(points.count), to: &out)
        var previous = TrackPoint(time: 0, latitudeE6: 0, longitudeE6: 0, altitudeDM: 0, horizontalAccuracyDM: 0, verticalAccuracyDM: 0)
        for point in points {
            writeSigned(point.time &- previous.time, to: &out)
            writeSigned(Int64(point.latitudeE6) - Int64(previous.latitudeE6), to: &out)
            writeSigned(Int64(point.longitudeE6) - Int64(previous.longitudeE6), to: &out)
            writeSigned(Int64(point.altitudeDM) - Int64(previous.altitudeDM), to: &out)
            writeSigned(Int64(point.horizontalAccuracyDM) - Int64(previous.horizontalAccuracyDM), to: &out)
            writeSigned(Int64(point.verticalAccuracyDM) - Int64(previous.verticalAccuracyDM), to: &out)
            previous = point
        }
        return Data(out)
    }

    public static func decode(_ data: Data) throws -> [TrackPoint] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [TrackPoint] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            guard index < bytes.count else { throw DecodingError.truncated }
            let found = bytes[index]
            guard found == version else { throw DecodingError.unsupportedVersion(found) }
            index += 1
            let count = Int(try readUnsigned(bytes, &index))
            var points: [TrackPoint] = []
            points.reserveCapacity(min(count, 1 << 20))
            var p = TrackPoint(time: 0, latitudeE6: 0, longitudeE6: 0, altitudeDM: 0, horizontalAccuracyDM: 0, verticalAccuracyDM: 0)
            for _ in 0..<count {
                p.time = p.time &+ (try readSigned(bytes, &index))
                p.latitudeE6 = Int32(truncatingIfNeeded: Int64(p.latitudeE6) + (try readSigned(bytes, &index)))
                p.longitudeE6 = Int32(truncatingIfNeeded: Int64(p.longitudeE6) + (try readSigned(bytes, &index)))
                p.altitudeDM = Int32(truncatingIfNeeded: Int64(p.altitudeDM) + (try readSigned(bytes, &index)))
                p.horizontalAccuracyDM = Int32(truncatingIfNeeded: Int64(p.horizontalAccuracyDM) + (try readSigned(bytes, &index)))
                p.verticalAccuracyDM = Int32(truncatingIfNeeded: Int64(p.verticalAccuracyDM) + (try readSigned(bytes, &index)))
                points.append(p)
            }
            return points
        }
    }

    private static func writeUnsigned(_ value: UInt64, to out: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    private static func writeSigned(_ value: Int64, to out: inout [UInt8]) {
        writeUnsigned(UInt64(bitPattern: (value << 1) ^ (value >> 63)), to: &out)
    }

    private static func readUnsigned(_ bytes: UnsafeBufferPointer<UInt8>, _ index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw DecodingError.truncated }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private static func readSigned(_ bytes: UnsafeBufferPointer<UInt8>, _ index: inout Int) throws -> Int64 {
        let raw = try readUnsigned(bytes, &index)
        return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
    }
}
