import Foundation
import MapKit
import MapQuestCore
import UIKit

/// The base map's look. The map is drawn on the device from OpenStreetMap vector
/// data without any labels, icons or POIs (`MapRenderPlan`); only the colours differ.
enum BaseMapStyle: String, Codable, CaseIterable, Identifiable {
    /// Coloured streets, parks and water.
    case streets
    /// Light grey.
    case light
    /// Dark.
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .streets: return tr("Streets")
        case .light: return tr("Light")
        case .dark: return tr("Dark")
        }
    }

    var palette: MapPalette {
        switch self {
        case .streets: return .streets
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Required credit, shown on the map (OpenFreeMap's attribution, as the providers word it).
    static let attribution = "OpenFreeMap © OpenMapTiles · Data © OpenStreetMap contributors" // not localized: credit line
    /// Drawn tiles go this deep; the vector data stops at zoom 14 and is enlarged (sharp).
    static let maximumZoom = 21
}

/// The map data: OpenFreeMap vector tiles (OpenMapTiles schema, from OpenStreetMap;
/// free, no key). Every downloaded tile is kept on disk, compressed, in
/// Application Support (excluded from backups) and reused offline and for every
/// deeper zoom; tiles older than 90 days are refreshed in the background when
/// used. Only tiles the map shows are requested (no bulk downloads), with an app
/// User-Agent. Thread-safe.
final class VectorTileStore: @unchecked Sendable {
    static let shared = VectorTileStore()
    static let tileJSONURL = URL(string: "https://tiles.openfreemap.org/planet")!
    static let diskLimit = 500_000_000
    private static let tileJSONKey = "VectorTileStore.tileJSON"

    private final class Entry {
        let tile: VectorTile
        init(_ tile: VectorTile) { self.tile = tile }
    }

    let directory: URL
    private let decoded = NSCache<NSString, Entry>()
    private let lock = NSLock()
    private var tileJSON: TileJSON?
    private var tileJSONState = TileJSONState.notRequested
    private var waitingForTileJSON: [(TileJSON?) -> Void] = []
    private var loading: [TileKey: [(Bool) -> Void]] = [:]
    private var failures: [TileKey: Date] = [:]
    private let session: URLSession

    private enum TileJSONState { case notRequested, requesting, fetched }

    private init() {
        decoded.countLimit = 24
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = support.appendingPathComponent("MapQuest/MapData")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        self.directory = directory

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil  // cached here, on disk, for good
        configuration.httpAdditionalHeaders = ["User-Agent": "MapQuest/\(version) (iOS)"] // not localized: HTTP header
        session = URLSession(configuration: configuration)

        if let data = UserDefaults.standard.data(forKey: Self.tileJSONKey) {
            tileJSON = try? JSONDecoder().decode(TileJSON.self, from: data)
        }
        let folder = directory
        DispatchQueue.global(qos: .utility).async {
            Self.trimDiskCache(folder, limit: Self.diskLimit)
            // Raster tiles of an earlier version of the app.
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: caches.appendingPathComponent("BaseMapTiles"))
        }
    }

    /// The deepest zoom with data (OpenFreeMap: 14).
    var dataMaximumZoom: Int {
        lock.lock()
        defer { lock.unlock() }
        return tileJSON?.maxzoom ?? 14
    }

    /// The data tile that holds `tile` (deeper zooms are drawn from the deepest data tile).
    func source(for tile: TileKey) -> TileKey {
        let maximum = dataMaximumZoom
        guard tile.zoom > maximum else { return tile }
        let levels = tile.zoom - maximum
        return TileKey(zoom: maximum, x: tile.x >> levels, y: tile.y >> levels)
    }

    private func file(_ tile: TileKey) -> URL {
        directory.appendingPathComponent("\(tile.zoom)/\(tile.x)/\(tile.y).mvt.z")
    }

    /// A data tile from memory or disk; never from the network.
    func cachedTile(_ source: TileKey) -> VectorTile? {
        let key = "\(source.zoom)/\(source.x)/\(source.y)" as NSString
        if let entry = decoded.object(forKey: key) { return entry.tile }
        let url = self.file(source)
        guard let compressed = try? Data(contentsOf: url) else { return nil }
        guard let data = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let tile = try? VectorTile(data: data, only: MapRenderPlan.layers) else {
            // Unreadable (interrupted write, old format): download it again.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        decoded.setObject(Entry(tile), forKey: key)
        // Stale while revalidating: old data is shown and replaced for next time.
        if let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(written) > 90 * 86_400 {
            load(source, replacing: true) { _ in }
        }
        return tile
    }

    /// Whether a data tile is on disk.
    func hasTile(_ source: TileKey) -> Bool {
        FileManager.default.fileExists(atPath: file(source).path)
    }

    /// Downloads a data tile (unless it is on disk or loading already); `completion`
    /// runs on an arbitrary thread with `true` once it is stored, `false` if that
    /// failed (failed tiles are not requested again within a minute).
    func load(_ source: TileKey, completion: @escaping (Bool) -> Void) {
        load(source, replacing: false, completion: completion)
    }

    private func load(_ source: TileKey, replacing: Bool, completion: @escaping (Bool) -> Void) {
        if !replacing, hasTile(source) { return completion(true) }
        lock.lock()
        if let failed = failures[source], Date().timeIntervalSince(failed) < 60 {
            lock.unlock()
            return completion(false)
        }
        if loading[source] != nil {
            loading[source]?.append(completion)
            lock.unlock()
            return
        }
        loading[source] = [completion]
        lock.unlock()

        withTileJSON { [weak self] tileJSON in
            guard let self else { return }
            guard let url = tileJSON?.url(for: source) else { return self.finish(source, success: false) }
            self.session.dataTask(with: url) { [weak self] data, response, _ in
                guard let self else { return }
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                      let raw = Self.gunzippedIfNeeded(data),
                      let tile = try? VectorTile(data: raw, only: MapRenderPlan.layers) else {
                    return self.finish(source, success: false)
                }
                let file = self.file(source)
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let compressed = try? (raw as NSData).compressed(using: .zlib) {
                    try? (compressed as Data).write(to: file, options: .atomic)
                }
                self.decoded.setObject(Entry(tile), forKey: "\(source.zoom)/\(source.x)/\(source.y)" as NSString)
                self.finish(source, success: true)
            }.resume()
        }
    }

    private func finish(_ source: TileKey, success: Bool) {
        lock.lock()
        let completions = loading.removeValue(forKey: source) ?? []
        if success { failures[source] = nil } else { failures[source] = Date() }
        lock.unlock()
        completions.forEach { $0(success) }
    }

    /// Where the tiles are: OpenFreeMap's TileJSON (its tile URLs change with every
    /// data release). Fetched once per launch; the last one is kept for offline use.
    private func withTileJSON(_ body: @escaping (TileJSON?) -> Void) {
        lock.lock()
        let known = tileJSON
        switch tileJSONState {
        case .fetched:
            lock.unlock()
            return body(known)
        case .requesting:
            if known != nil {
                lock.unlock()
                return body(known)
            }
            waitingForTileJSON.append(body)
            lock.unlock()
            return
        case .notRequested:
            tileJSONState = .requesting
            if known == nil { waitingForTileJSON.append(body) }
            lock.unlock()
        }
        if known != nil { body(known) }
        session.dataTask(with: Self.tileJSONURL) { [weak self] data, response, _ in
            guard let self else { return }
            var fetched: TileJSON?
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(TileJSON.self, from: data), !decoded.tiles.isEmpty {
                fetched = decoded
                UserDefaults.standard.set(data, forKey: Self.tileJSONKey)
            }
            self.lock.lock()
            if let fetched { self.tileJSON = fetched }
            // Without an answer, try again with the next tile.
            self.tileJSONState = fetched == nil ? .notRequested : .fetched
            let result = self.tileJSON
            let waiting = self.waitingForTileJSON
            self.waitingForTileJSON = []
            self.lock.unlock()
            waiting.forEach { $0(result) }
        }.resume()
    }

    /// URLSession decodes gzip transfer encoding itself; this also accepts gzip bodies.
    private static func gunzippedIfNeeded(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return data }
        let flags = bytes[3]
        var offset = 10
        if flags & 4 != 0, offset + 2 <= bytes.count { offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8 }
        if flags & 8 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 16 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 2 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { return nil }
        let deflated = Data(bytes[offset..<(bytes.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: Disk cache

    /// Bytes of map data on disk.
    func diskUsage() -> Int {
        Self.files(in: directory).reduce(0) { $0 + $1.size }
    }

    /// Deletes all map data (it is downloaded again when needed).
    func clear() {
        decoded.removeAllObjects()
        for file in Self.files(in: directory) { try? FileManager.default.removeItem(at: file.url) }
    }

    private static func files(in directory: URL) -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var files: [(url: URL, size: Int, date: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        return files
    }

    /// Deletes the least recently written tiles beyond `limit` bytes.
    private static func trimDiskCache(_ directory: URL, limit: Int) {
        let all = Self.files(in: directory)
        var total = all.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        for file in all.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
            if total <= limit * 8 / 10 { break }
        }
    }
}

/// Map tiles drawn on the device from the vector data, one style; drawn tiles are
/// kept in memory. Thread-safe: the map's renderer reads tiles on MapKit's drawing threads.
final class BaseMapTiles: @unchecked Sendable {
    let style: BaseMapStyle
    private let store = VectorTileStore.shared
    /// Pixels per tile side (256 points at @2x).
    static let tileSize = 512

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let memory = NSCache<NSString, Entry>()

    private static let instancesLock = NSLock()
    private static var instances: [BaseMapStyle: BaseMapTiles] = [:]

    /// One tile source per style for the whole app.
    static func shared(_ style: BaseMapStyle) -> BaseMapTiles {
        instancesLock.lock()
        defer { instancesLock.unlock() }
        if let tiles = instances[style] { return tiles }
        let tiles = BaseMapTiles(style: style)
        instances[style] = tiles
        return tiles
    }

    private init(style: BaseMapStyle) {
        self.style = style
        memory.countLimit = 96
    }

    private func key(_ tile: TileKey) -> NSString { "\(tile.zoom)/\(tile.x)/\(tile.y)" as NSString }

    /// The drawn tile from memory, or drawn now from stored map data when `draw`
    /// is set; never from the network.
    func cachedImage(_ tile: TileKey, draw: Bool = true) -> CGImage? {
        if let entry = memory.object(forKey: key(tile)) { return entry.image }
        guard draw else { return nil }
        let source = store.source(for: tile)
        guard let data = store.cachedTile(source),
              let image = Self.render(data, source: source, target: tile, palette: style.palette) else { return nil }
        memory.setObject(Entry(image), forKey: key(tile))
        return image
    }

    /// The best image for a tile: the tile itself or the matching part of an
    /// ancestor (blurrier). The rectangle is in the image's pixels, origin top left.
    func bestImage(for tile: TileKey) -> (image: CGImage, crop: CGRect, exact: Bool)? {
        if let image = cachedImage(tile) {
            return (image, CGRect(x: 0, y: 0, width: image.width, height: image.height), true)
        }
        guard tile.zoom > 0 else { return nil }
        // Coarser tiles: one already drawn, else one drawn now from stored map data
        // (after a restart memory is empty, but the disk cache is not).
        for draw in [false, true] {
            for levels in 1...min(8, tile.zoom) {
                let ancestor = TileKey(zoom: tile.zoom - levels, x: tile.x >> levels, y: tile.y >> levels)
                if draw, !store.hasTile(store.source(for: ancestor)) { continue }
                guard let image = cachedImage(ancestor, draw: draw) else { continue }
                let parts = 1 << levels
                let size = Double(image.width) / Double(parts)
                guard size >= 2 else { break }
                let dx = tile.x - (ancestor.x << levels), dy = tile.y - (ancestor.y << levels)
                return (image, CGRect(x: Double(dx) * size, y: Double(dy) * size, width: size, height: size), false)
            }
        }
        return nil
    }

    /// Downloads the map data for a tile; `completion` runs on an arbitrary thread
    /// with `true` once the tile can be drawn.
    func load(_ tile: TileKey, completion: @escaping (Bool) -> Void) {
        store.load(store.source(for: tile), completion: completion)
    }

    /// Draws a tile: land colour, then the plan's fills and strokes.
    private static func render(_ tile: VectorTile, source: TileKey, target: TileKey, palette: MapPalette) -> CGImage? {
        let size = tileSize
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Pixel coordinates with y down: the image's first row is the tile's top.
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        context.setFillColor(color(palette.color(.land)))
        context.fill(bounds)
        context.clip(to: bounds)
        context.setLineJoin(.round)
        for command in MapRenderPlan.commands(for: tile, source: source, target: target, size: Double(size)) {
            let cgColor = color(palette.color(command.role))
            switch command.kind {
            case .fill:
                context.setFillColor(cgColor)
                for shape in command.shapes {
                    let path = CGMutablePath()
                    for ring in shape { add(ring, to: path, closed: true) }
                    context.addPath(path)
                    context.fillPath(using: .evenOdd)
                }
            case let .stroke(width, dash):
                context.setStrokeColor(cgColor)
                context.setLineWidth(CGFloat(width))
                context.setLineCap(dash == nil ? .round : .butt)
                context.setLineDash(phase: 0, lengths: (dash ?? []).map { CGFloat($0) })
                let path = CGMutablePath()
                for shape in command.shapes {
                    for line in shape { add(line, to: path, closed: false) }
                }
                context.addPath(path)
                context.strokePath()
            }
        }
        return context.makeImage()
    }

    private static func add(_ points: [MapPixel], to path: CGMutablePath, closed: Bool) {
        guard let first = points.first else { return }
        path.move(to: CGPoint(x: first.x, y: first.y))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
        if closed { path.closeSubpath() }
    }

    private static func color(_ color: MapColor) -> CGColor {
        CGColor(red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
    }

    // MARK: Whole images (3D ground)

    /// The base map of a world rectangle as one image of about `pixelWidth` pixels,
    /// or `nil` if map data is missing (no network).
    func image(of rect: WorldRect, pixelWidth: Int) async -> CGImage? {
        guard rect.width > 0, rect.height > 0, pixelWidth > 0 else { return nil }
        // Tile pixels at about the output resolution.
        let tilesAcross = Double(pixelWidth) / Double(Self.tileSize) * Double(WebMercator.worldSize) / Double(rect.width)
        let zoom = max(0, min(BaseMapStyle.maximumZoom, Int(log2(max(tilesAcross, 1)).rounded())))
        let range = TileRange(covering: rect, zoom: zoom)
        guard range.count > 0, range.count <= 64 else { return nil }
        // Missing data tiles are loaded in parallel.
        let missing = Set(range.map { store.source(for: $0) }).filter { !store.hasTile($0) }
        let complete = await withTaskGroup(of: Bool.self) { group in
            for source in missing {
                group.addTask { await self.loaded(source) }
            }
            var complete = true
            for await success in group { complete = complete && success }
            return complete
        }
        guard complete else { return nil }
        var images: [TileKey: CGImage] = [:]
        for tile in range {
            guard let image = cachedImage(tile) else { return nil }
            images[tile] = image
        }
        let pixelHeight = max(1, Int((Double(pixelWidth) * Double(rect.height) / Double(rect.width)).rounded()))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let sx = Double(pixelWidth) / Double(rect.width), sy = Double(pixelHeight) / Double(rect.height)
        for (tile, image) in images {
            let t = tile.worldRect
            let x = Double(t.minX - rect.minX) * sx, yTop = Double(t.minY - rect.minY) * sy
            let w = Double(t.width) * sx, h = Double(t.height) * sy
            // Bitmap contexts are y-up: the tile's top edge is at height − yTop.
            context.draw(image, in: CGRect(x: x, y: Double(pixelHeight) - yTop - h, width: w, height: h))
        }
        return context.makeImage()
    }

    private func loaded(_ source: TileKey) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.load(source) { success in continuation.resume(returning: success) }
        }
    }
}
