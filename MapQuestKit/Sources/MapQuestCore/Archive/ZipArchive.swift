import Foundation
#if canImport(Compression)
import Compression
#endif

/// A minimal ZIP archive (PKWARE APPNOTE): files stored or deflated, UTF-8 names,
/// no encryption, no ZIP64 (archives and entries below 4 GB, at most 65,535
/// entries). Written and read entry by entry through a file handle, so large
/// archives never have to fit in memory. Archives from other tools (Finder,
/// `zip`) can be read as long as they keep within these limits.
public enum ZipError: Error, Equatable, LocalizedError {
    case notAZipArchive
    case unsupported(String)
    case missingEntry(String)
    case corrupt(String)
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .notAZipArchive: return "Not a ZIP archive" // not localized: shown via the app's own messages
        case .unsupported(let what): return "Unsupported ZIP feature: \(what)" // not localized
        case .missingEntry(let path): return "Missing in the archive: \(path)" // not localized
        case .corrupt(let what): return "Damaged archive: \(what)" // not localized
        case .tooLarge: return "The archive is too large (4 GB at most)" // not localized
        }
    }
}

/// CRC-32 (IEEE 802.3), as ZIP uses it.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data, continuing crc: UInt32 = 0) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }
}

/// Raw DEFLATE (RFC 1951), as ZIP entries use it; where the platform has it (Apple's
/// Compression framework). Elsewhere entries are stored and deflated ones cannot be read.
public enum Deflate {
    public static var isAvailable: Bool {
        #if canImport(Compression)
        return true
        #else
        return false
        #endif
    }

    /// The compressed data, or `nil` if it would not be smaller.
    public static func compress(_ data: Data) -> Data? {
        #if canImport(Compression)
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 64
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0, written < data.count else { return nil }
        return output.prefix(written)
        #else
        return nil
        #endif
    }

    public static func decompress(_ data: Data, size: Int) throws -> Data {
        #if canImport(Compression)
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, size, source, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw ZipError.corrupt("deflated data") }
        return output
        #else
        throw ZipError.unsupported("deflate")
        #endif
    }
}

/// Writes a ZIP archive entry by entry.
public final class ZipWriter {
    private struct Entry {
        var path: Data
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt32
        var size: UInt32
        var offset: UInt32
        var time: UInt16
        var date: UInt16
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0
    private var isFinished = false

    /// Creates (or replaces) the archive file.
    public init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        if !isFinished { try? handle.close() }
    }

    /// Adds a file. `compress`: deflate it where that makes it smaller (not for JPEGs).
    public func add(_ path: String, data: Data, compress: Bool = true, modified: Date = Date()) throws {
        precondition(!isFinished, "the archive is finished")
        guard entries.count < 0xFFFF, data.count < 0xFFFF_FFFF, offset < 0xFFFF_FFFF else { throw ZipError.tooLarge }
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let packed = compress ? Deflate.compress(data) : nil
        let body = packed ?? data
        let (time, date) = Self.dosTime(modified)
        let entry = Entry(
            path: name, method: packed == nil ? 0 : 8, crc: crc, compressedSize: UInt32(body.count),
            size: UInt32(data.count), offset: UInt32(offset), time: time, date: date
        )
        var header = Data()
        header.append(le32: 0x0403_4B50)
        header.append(le16: 20)              // version needed
        header.append(le16: 0x0800)          // UTF-8 names
        header.append(le16: entry.method)
        header.append(le16: time)
        header.append(le16: date)
        header.append(le32: crc)
        header.append(le32: entry.compressedSize)
        header.append(le32: entry.size)
        header.append(le16: UInt16(name.count))
        header.append(le16: 0)               // extra field
        header.append(name)
        try write(header)
        try write(body)
        entries.append(entry)
    }

    /// Writes the central directory and closes the file.
    public func finish() throws {
        guard !isFinished else { return }
        let start = offset
        for entry in entries {
            var record = Data()
            record.append(le32: 0x0201_4B50)
            record.append(le16: 0x031E)      // made by: Unix, 3.0
            record.append(le16: 20)
            record.append(le16: 0x0800)
            record.append(le16: entry.method)
            record.append(le16: entry.time)
            record.append(le16: entry.date)
            record.append(le32: entry.crc)
            record.append(le32: entry.compressedSize)
            record.append(le32: entry.size)
            record.append(le16: UInt16(entry.path.count))
            record.append(le16: 0)           // extra
            record.append(le16: 0)           // comment
            record.append(le16: 0)           // disk
            record.append(le16: 0)           // internal attributes
            record.append(le32: 0o100644 << 16) // external: a regular file, rw-r--r--
            record.append(le32: entry.offset)
            record.append(entry.path)
            try write(record)
        }
        guard offset < 0xFFFF_FFFF else { throw ZipError.tooLarge }
        var end = Data()
        end.append(le32: 0x0605_4B50)
        end.append(le16: 0)
        end.append(le16: 0)
        end.append(le16: UInt16(entries.count))
        end.append(le16: UInt16(entries.count))
        end.append(le32: UInt32(offset - start))
        end.append(le32: UInt32(start))
        end.append(le16: 0)
        try write(end)
        try handle.close()
        isFinished = true
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    /// MS-DOS time and date (local time, 2 s resolution).
    private static func dosTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(1980, min(2107, c.year ?? 1980))
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dosDate: Int = ((year - 1980) << 9) | (month << 5) | day
        return (UInt16(time), UInt16(dosDate))
    }
}

/// Reads a ZIP archive: the list of entries, and each entry's data on request.
public final class ZipReader: @unchecked Sendable {
    public struct Entry: Hashable, Sendable {
        public var path: String
        public var method: UInt16
        public var crc: UInt32
        public var compressedSize: Int
        public var size: Int
        fileprivate var offset: UInt64
    }

    public let entries: [Entry]
    private let byPath: [String: Entry]
    private let handle: FileHandle

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let length = try handle.seekToEnd()
        guard length >= 22 else { throw ZipError.notAZipArchive }
        // The end of central directory record, within the last 64 KB (a comment may follow it).
        let tailLength = min(length, 22 + 0xFFFF)
        try handle.seek(toOffset: length - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard let endIndex = Self.lastIndex(of: 0x0605_4B50, in: tail) else { throw ZipError.notAZipArchive }
        let count = Int(tail.le16(at: endIndex + 10))
        let directorySize = Int(tail.le32(at: endIndex + 12))
        let directoryOffset = UInt64(tail.le32(at: endIndex + 16))
        if count == 0xFFFF || directoryOffset == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: directorySize) ?? Data()
        guard directory.count == directorySize else { throw ZipError.corrupt("central directory") }
        var entries: [Entry] = []
        var position = 0
        for _ in 0..<count {
            guard position + 46 <= directory.count, directory.le32(at: position) == 0x0201_4B50 else {
                throw ZipError.corrupt("central directory")
            }
            let flags = directory.le16(at: position + 8)
            if flags & 1 != 0 { throw ZipError.unsupported("encryption") }
            let nameLength = Int(directory.le16(at: position + 28))
            let extraLength = Int(directory.le16(at: position + 30))
            let commentLength = Int(directory.le16(at: position + 32))
            guard position + 46 + nameLength <= directory.count else { throw ZipError.corrupt("central directory") }
            let nameData = directory.subdata(in: (position + 46)..<(position + 46 + nameLength))
            let path = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            let compressedSize = directory.le32(at: position + 20), size = directory.le32(at: position + 24)
            let offset = directory.le32(at: position + 42)
            if compressedSize == 0xFFFF_FFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
                throw ZipError.unsupported("ZIP64")
            }
            entries.append(Entry(
                path: path, method: directory.le16(at: position + 10), crc: directory.le32(at: position + 16),
                compressedSize: Int(compressedSize), size: Int(size), offset: UInt64(offset)
            ))
            position += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
        byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    deinit {
        try? handle.close()
    }

    public func contains(_ path: String) -> Bool { byPath[path] != nil }

    /// The entry's data, checked against its CRC.
    public func data(_ path: String) throws -> Data {
        guard let entry = byPath[path] else { throw ZipError.missingEntry(path) }
        return try data(entry)
    }

    public func data(_ entry: Entry) throws -> Data {
        try handle.seek(toOffset: entry.offset)
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.le32(at: 0) == 0x0403_4B50 else { throw ZipError.corrupt(entry.path) }
        let skip = UInt64(header.le16(at: 26)) + UInt64(header.le16(at: 28))
        try handle.seek(toOffset: entry.offset + 30 + skip)
        let body = try handle.read(upToCount: entry.compressedSize) ?? Data()
        guard body.count == entry.compressedSize else { throw ZipError.corrupt(entry.path) }
        let data: Data
        switch entry.method {
        case 0: data = body
        case 8: data = try Deflate.decompress(body, size: entry.size)
        default: throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard data.count == entry.size, CRC32.checksum(data) == entry.crc else { throw ZipError.corrupt(entry.path) }
        return data
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = data.count - 22
        while index >= 0 {
            if data.le32(at: index) == signature { return index }
            index -= 1
        }
        return nil
    }
}

extension Data {
    mutating func append(le16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(le32 value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    func le16(at index: Int) -> UInt16 {
        let i = startIndex + index
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func le32(at index: Int) -> UInt32 {
        let i = startIndex + index
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
