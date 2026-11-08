import Foundation

/// A decoded Mapbox Vector Tile (MVT 2.1, protocol buffers), as served by
/// OpenFreeMap in the OpenMapTiles schema. Only what drawing needs: layer names,
/// feature types, properties and geometry in tile coordinates (0…extent, y down).
public struct VectorTile: Sendable {
    public enum GeometryType: Int, Sendable {
        case unknown = 0, point = 1, lineString = 2, polygon = 3
    }

    public enum Value: Hashable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)

        public var string: String? {
            if case let .string(value) = self { return value }
            return nil
        }

        public var number: Double? {
            if case let .number(value) = self { return value }
            return nil
        }
    }

    public struct Point: Hashable, Sendable {
        public var x: Int32
        public var y: Int32

        public init(x: Int32, y: Int32) {
            self.x = x
            self.y = y
        }
    }

    public struct Feature: Sendable {
        public var type: GeometryType
        public var properties: [String: Value]
        /// Lines: their parts. Polygons: their rings, closed (first point repeated);
        /// exterior rings run clockwise on screen, holes anticlockwise. Points: empty.
        public var paths: [[Point]]

        public var className: String? { properties["class"]?.string }
    }

    public struct Layer: Sendable {
        public var name: String
        public var extent: Int
        public var features: [Feature]
    }

    public enum DecodingError: Error, Equatable {
        case truncated
        case malformed
    }

    public var layers: [String: Layer]

    /// Decodes a tile; `only` limits decoding to these layers (the others are skipped cheaply).
    public init(data: Data, only names: Set<String>? = nil) throws {
        var reader = ProtobufReader(bytes: [UInt8](data))
        var layers: [String: Layer] = [:]
        while !reader.isAtEnd {
            let (field, wireType) = try reader.key()
            if field == 3, wireType == 2 {
                var layerReader = try reader.message()
                if let layer = try Self.layer(&layerReader, only: names) {
                    layers[layer.name] = layer
                }
            } else {
                try reader.skip(wireType)
            }
        }
        self.layers = layers
    }

    private static func layer(_ reader: inout ProtobufReader, only names: Set<String>?) throws -> Layer? {
        var name = ""
        var extent = 4096
        var keys: [String] = []
        var values: [Value] = []
        var rawFeatures: [ProtobufReader] = []
        while !reader.isAtEnd {
            let (field, wireType) = try reader.key()
            switch (field, wireType) {
            case (1, 2):
                name = try reader.string()
                // Layers come with their name first: skip unwanted ones early.
                if let names, !names.contains(name) { return nil }
            case (2, 2): rawFeatures.append(try reader.message())
            case (3, 2): keys.append(try reader.string())
            case (4, 2):
                var valueReader = try reader.message()
                values.append(try value(&valueReader))
            case (5, 0): extent = Int(try reader.varint())
            default: try reader.skip(wireType)
            }
        }
        if let names, !names.contains(name) { return nil }
        var features: [Feature] = []
        features.reserveCapacity(rawFeatures.count)
        for var featureReader in rawFeatures {
            features.append(try feature(&featureReader, keys: keys, values: values))
        }
        return Layer(name: name, extent: extent, features: features)
    }

    private static func value(_ reader: inout ProtobufReader) throws -> Value {
        var result = Value.string("")
        while !reader.isAtEnd {
            let (field, wireType) = try reader.key()
            switch (field, wireType) {
            case (1, 2): result = .string(try reader.string())
            case (2, 5): result = .number(Double(Float(bitPattern: try reader.fixed32())))
            case (3, 1): result = .number(Double(bitPattern: try reader.fixed64()))
            case (4, 0): result = .number(Double(Int64(bitPattern: try reader.varint())))
            case (5, 0): result = .number(Double(try reader.varint()))
            case (6, 0): result = .number(Double(ProtobufReader.zigzag(try reader.varint())))
            case (7, 0): result = .bool(try reader.varint() != 0)
            default: try reader.skip(wireType)
            }
        }
        return result
    }

    private static func feature(_ reader: inout ProtobufReader, keys: [String], values: [Value]) throws -> Feature {
        var type = GeometryType.unknown
        var tags: [UInt64] = []
        var commands: [UInt64] = []
        while !reader.isAtEnd {
            let (field, wireType) = try reader.key()
            switch (field, wireType) {
            case (2, 2): tags = try reader.packedVarints()
            case (2, 0): tags.append(try reader.varint())
            case (3, 0): type = GeometryType(rawValue: Int(try reader.varint())) ?? .unknown
            case (4, 2): commands = try reader.packedVarints()
            case (4, 0): commands.append(try reader.varint())
            default: try reader.skip(wireType)
            }
        }
        var properties: [String: Value] = [:]
        var i = 0
        while i + 1 < tags.count {
            let k = Int(tags[i]), v = Int(tags[i + 1])
            if k < keys.count, v < values.count { properties[keys[k]] = values[v] }
            i += 2
        }
        let paths = type == .point || type == .unknown ? [] : try geometry(commands, closeRings: type == .polygon)
        return Feature(type: type, properties: properties, paths: paths)
    }

    /// Decodes the command stream: MoveTo (1), LineTo (2), ClosePath (7), zig-zag deltas.
    private static func geometry(_ commands: [UInt64], closeRings: Bool) throws -> [[Point]] {
        var paths: [[Point]] = []
        var current: [Point] = []
        var x: Int64 = 0, y: Int64 = 0
        var i = 0
        while i < commands.count {
            let command = commands[i]
            let id = command & 7, count = Int(command >> 3)
            i += 1
            switch id {
            case 1, 2:
                guard i + 2 * count <= commands.count else { throw DecodingError.truncated }
                for _ in 0..<count {
                    x += ProtobufReader.zigzag(commands[i])
                    y += ProtobufReader.zigzag(commands[i + 1])
                    i += 2
                    if id == 1 {
                        if current.count > 1 { paths.append(current) }
                        current = []
                    }
                    current.append(Point(x: Int32(clamping: x), y: Int32(clamping: y)))
                }
            case 7:
                if closeRings, let first = current.first {
                    current.append(first)
                }
            default:
                throw DecodingError.malformed
            }
        }
        if current.count > 1 { paths.append(current) }
        return paths
    }
}

/// Reads protocol buffer wire format.
struct ProtobufReader {
    private let bytes: [UInt8]
    private var position: Int
    private let end: Int

    init(bytes: [UInt8]) {
        self.init(bytes: bytes, start: 0, end: bytes.count)
    }

    private init(bytes: [UInt8], start: Int, end: Int) {
        self.bytes = bytes
        self.position = start
        self.end = end
    }

    var isAtEnd: Bool { position >= end }

    static func zigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < end else { throw VectorTile.DecodingError.truncated }
            let byte = bytes[position]
            position += 1
            if shift < 64 { result |= UInt64(byte & 0x7F) << shift }
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift < 70 else { throw VectorTile.DecodingError.malformed }
        }
    }

    mutating func key() throws -> (field: Int, wireType: Int) {
        let key = try varint()
        return (Int(key >> 3), Int(key & 7))
    }

    mutating func fixed32() throws -> UInt32 {
        guard position + 4 <= end else { throw VectorTile.DecodingError.truncated }
        var value: UInt32 = 0
        for k in 0..<4 { value |= UInt32(bytes[position + k]) << (8 * UInt32(k)) }
        position += 4
        return value
    }

    mutating func fixed64() throws -> UInt64 {
        guard position + 8 <= end else { throw VectorTile.DecodingError.truncated }
        var value: UInt64 = 0
        for k in 0..<8 { value |= UInt64(bytes[position + k]) << (8 * UInt64(k)) }
        position += 8
        return value
    }

    private mutating func lengthDelimited() throws -> Range<Int> {
        let length = Int(try varint())
        guard length >= 0, position + length <= end else { throw VectorTile.DecodingError.truncated }
        let range = position..<(position + length)
        position += length
        return range
    }

    /// A reader for an embedded message (shares the bytes, no copy).
    mutating func message() throws -> ProtobufReader {
        let range = try lengthDelimited()
        return ProtobufReader(bytes: bytes, start: range.lowerBound, end: range.upperBound)
    }

    mutating func string() throws -> String {
        let range = try lengthDelimited()
        return String(decoding: bytes[range], as: UTF8.self)
    }

    mutating func packedVarints() throws -> [UInt64] {
        var inner = try message()
        var values: [UInt64] = []
        while !inner.isAtEnd { values.append(try inner.varint()) }
        return values
    }

    mutating func skip(_ wireType: Int) throws {
        switch wireType {
        case 0: _ = try varint()
        case 1:
            guard position + 8 <= end else { throw VectorTile.DecodingError.truncated }
            position += 8
        case 2: _ = try lengthDelimited()
        case 5:
            guard position + 4 <= end else { throw VectorTile.DecodingError.truncated }
            position += 4
        default: throw VectorTile.DecodingError.malformed
        }
    }
}
