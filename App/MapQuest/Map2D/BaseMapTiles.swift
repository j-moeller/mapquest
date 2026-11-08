import Foundation
import ImageIO
import MapKit
import MapQuestCore
import UIKit

/// The base map: raster tiles without any labels, icons or POIs (CARTO basemaps,
/// rendered from OpenStreetMap). Apple Maps cannot hide its labels (only its
/// satellite imagery has none) and does not let apps process its map image, so
/// the fog of war could not be drawn into it; with own tiles the fog is drawn
/// into the map itself (`FogMapRenderer`).
enum BaseMapStyle: String, Codable, CaseIterable, Identifiable {
    /// Coloured streets, parks and water ("Voyager").
    case streets
    /// Light grey ("Positron").
    case light
    /// Dark ("Dark Matter").
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .streets: return "Streets"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    private var path: String {
        switch self {
        case .streets: return "rastertiles/voyager_nolabels"
        case .light: return "light_nolabels"
        case .dark: return "dark_nolabels"
        }
    }

    /// Tiles are 256 points, delivered at 512 pixels (@2x).
    func url(for tile: TileKey) -> URL? {
        let server = ["a", "b", "c", "d"][(tile.x + tile.y) % 4]
        return URL(string: "https://\(server).basemaps.cartocdn.com/\(path)/\(tile.zoom)/\(tile.x)/\(tile.y)@2x.png")
    }

    /// Required credit, shown on the map.
    static let attribution = "© OpenStreetMap contributors © CARTO"
    /// Deeper zooms draw these tiles enlarged.
    static let maximumZoom = 19
}

/// Loads and caches base map tiles (memory and disk). Thread-safe: the map's
/// renderer reads tiles on MapKit's drawing threads.
final class BaseMapTiles: @unchecked Sendable {
    let style: BaseMapStyle

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let memory = NSCache<NSString, Entry>()
    private let lock = NSLock()
    private var loading: [TileKey: [(Bool) -> Void]] = [:]
    private var failures: [TileKey: Date] = [:]
    private let directory: URL
    private let session: URLSession

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
        memory.countLimit = 160
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("BaseMapTiles").appendingPathComponent(style.rawValue)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        let directory = self.directory
        DispatchQueue.global(qos: .utility).async { Self.trimDiskCache(directory, limit: 300_000_000) }
    }

    private func key(_ tile: TileKey) -> NSString { "\(tile.zoom)/\(tile.x)/\(tile.y)" as NSString }

    private func file(_ tile: TileKey) -> URL {
        directory.appendingPathComponent("\(tile.zoom)/\(tile.x)/\(tile.y).png")
    }

    /// The tile from memory, or from disk when `disk` is set; never from the network.
    func cachedImage(_ tile: TileKey, disk: Bool = true) -> CGImage? {
        if let entry = memory.object(forKey: key(tile)) { return entry.image }
        guard disk, let data = try? Data(contentsOf: file(tile)), let image = Self.decode(data) else { return nil }
        memory.setObject(Entry(image), forKey: key(tile))
        return image
    }

    /// The best image for a tile: the tile itself or the matching part of a cached
    /// ancestor (blurrier). The rectangle is in the image's pixels, origin top left.
    func bestImage(for tile: TileKey) -> (image: CGImage, crop: CGRect, exact: Bool)? {
        if let image = cachedImage(tile) {
            return (image, CGRect(x: 0, y: 0, width: image.width, height: image.height), true)
        }
        guard tile.zoom > 0 else { return nil }
        for levels in 1...min(8, tile.zoom) {
            let ancestor = TileKey(zoom: tile.zoom - levels, x: tile.x >> levels, y: tile.y >> levels)
            guard let image = cachedImage(ancestor, disk: false) else { continue }
            let parts = 1 << levels
            let size = Double(image.width) / Double(parts)
            guard size >= 2 else { return nil }
            let dx = tile.x - (ancestor.x << levels), dy = tile.y - (ancestor.y << levels)
            return (image, CGRect(x: Double(dx) * size, y: Double(dy) * size, width: size, height: size), false)
        }
        return nil
    }

    /// Loads a tile from the network (unless it is loading already); `completion`
    /// runs on an arbitrary thread with `true` once the tile is cached, `false` if it
    /// failed (tiles that failed within the last minute are not requested again).
    func load(_ tile: TileKey, completion: @escaping (Bool) -> Void) {
        lock.lock()
        if let failed = failures[tile], Date().timeIntervalSince(failed) < 60 {
            lock.unlock()
            completion(false)
            return
        }
        if loading[tile] != nil {
            loading[tile]?.append(completion)
            lock.unlock()
            return
        }
        loading[tile] = [completion]
        lock.unlock()

        guard let url = style.url(for: tile) else { return finish(tile, success: false) }
        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200, let image = Self.decode(data) else {
                return self.finish(tile, success: false)
            }
            let file = self.file(tile)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            self.memory.setObject(Entry(image), forKey: self.key(tile))
            self.finish(tile, success: true)
        }.resume()
    }

    private func finish(_ tile: TileKey, success: Bool) {
        lock.lock()
        let completions = loading.removeValue(forKey: tile) ?? []
        if success { failures[tile] = nil } else { failures[tile] = Date() }
        lock.unlock()
        completions.forEach { $0(success) }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// Deletes the least recently written tiles beyond `limit` bytes.
    private static func trimDiskCache(_ directory: URL, limit: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            files.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > limit else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
            if total <= limit * 8 / 10 { break }
        }
    }

    // MARK: Whole images (3D ground)

    /// The base map of a world rectangle as one image of about `pixelWidth` pixels,
    /// or `nil` if tiles are missing (no network).
    func image(of rect: WorldRect, pixelWidth: Int) async -> CGImage? {
        guard rect.width > 0, rect.height > 0, pixelWidth > 0 else { return nil }
        // Tile pixels (512 per tile) at about the output resolution.
        let tilesAcross = Double(pixelWidth) / 512 * Double(WebMercator.worldSize) / Double(rect.width)
        let zoom = max(0, min(BaseMapStyle.maximumZoom, Int(log2(max(tilesAcross, 1)).rounded())))
        let range = TileRange(covering: rect, zoom: zoom)
        guard range.count > 0, range.count <= 64 else { return nil }
        // Missing tiles are loaded in parallel.
        let missing = range.filter { cachedImage($0) == nil }
        let complete = await withTaskGroup(of: Bool.self) { group in
            for tile in missing {
                group.addTask { await self.loaded(tile) != nil }
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

    private func loaded(_ tile: TileKey) async -> CGImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            load(tile) { [weak self] success in
                continuation.resume(returning: success ? self?.cachedImage(tile, disk: false) : nil)
            }
        }
    }
}
