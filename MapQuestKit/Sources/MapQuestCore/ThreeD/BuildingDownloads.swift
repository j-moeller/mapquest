import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads OpenStreetMap buildings from an Overpass API server.
///
/// OSM data © OpenStreetMap contributors, ODbL. Overpass servers are shared
/// infrastructure: callers must cache results (see `CachingBuildingSource`).
public struct OverpassClient: Sendable {
    public var endpoint: URL
    public var userAgent: String
    public var timeout: TimeInterval

    public init(
        endpoint: URL = URL(string: "https://overpass-api.de/api/interpreter")!,
        userAgent: String = "MapQuest/0.1 (fog-of-war map prototype)",
        timeout: TimeInterval = 60
    ) {
        self.endpoint = endpoint
        self.userAgent = userAgent
        self.timeout = timeout
    }

    /// The Overpass QL query for all building outlines in a box.
    public static func query(for box: GeoBoundingBox) -> String {
        let bbox = String(format: "%.6f,%.6f,%.6f,%.6f", box.minLatitude, box.minLongitude, box.maxLatitude, box.maxLongitude)
        return """
        [out:json][timeout:90];
        (
          way["building"](\(bbox));
          relation["building"]["type"="multipolygon"](\(bbox));
          way["man_made"="tower"]["height"](\(bbox));
        );
        out tags geom;
        """
    }

    public func buildings(in box: GeoBoundingBox) async throws -> [Building] {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = Self.query(for: box).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        request.httpBody = Data("data=\(encoded)".utf8)

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: BuildingSourceError.unavailable(error.localizedDescription))
                } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    continuation.resume(throwing: BuildingSourceError.unavailable("Overpass HTTP \(http.statusCode)"))
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }.resume()
        }
        return try OverpassBuildingParser.buildings(from: data)
    }
}

/// Persistent storage for downloaded buildings, organised by download tiles.
public protocol BuildingCache: Sendable {
    func buildings(in rect: WorldRect) async throws -> [Building]
    func isDownloaded(_ tile: TileKey) async throws -> Bool
    /// Stores buildings and marks `tiles` as downloaded (atomically).
    func store(_ buildings: [Building], downloadedTiles tiles: [TileKey]) async throws
}

/// Serves buildings from a persistent cache and downloads missing areas on
/// demand, one zoom-14 tile (≈ 1.5 km in Berlin) at a time. Recently used tiles
/// are kept in memory, so repeated viewshed computations do not hit the disk.
/// After a failed download a tile is not retried for `retryInterval`, so that
/// being offline does not stall the processing of every position fix.
public actor CachingBuildingSource: BuildingSource {
    public typealias Download = @Sendable (GeoBoundingBox) async throws -> [Building]

    public nonisolated let downloadZoom: Int
    public nonisolated let retryInterval: TimeInterval
    private let cache: any BuildingCache
    private let download: Download?
    private let memoryLimit: Int
    private let now: @Sendable () -> Date
    private var memory: [TileKey: [Building]] = [:]
    private var recentlyUsed: [TileKey] = []
    private var inFlight: [TileKey: Task<[Building], Error>] = [:]
    private var failures: [TileKey: (date: Date, message: String)] = [:]

    /// - Parameters:
    ///   - download: Fetches buildings for a box; `nil` makes the source offline-only.
    public init(
        cache: any BuildingCache,
        download: Download?,
        downloadZoom: Int = 14,
        memoryLimit: Int = 24,
        retryInterval: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = cache
        self.download = download
        self.downloadZoom = downloadZoom
        self.memoryLimit = memoryLimit
        self.retryInterval = retryInterval
        self.now = now
    }

    public func buildings(in rect: WorldRect) async throws -> [Building] {
        var seen = Set<Int64>()
        var result: [Building] = []
        for tile in TileRange(covering: rect, zoom: downloadZoom) {
            for building in try await tileBuildings(tile)
            where building.bounds.intersects(rect) && seen.insert(building.id).inserted {
                result.append(building)
            }
        }
        return result
    }

    private func tileBuildings(_ tile: TileKey) async throws -> [Building] {
        if let cached = memory[tile] {
            touch(tile)
            return cached
        }
        if let running = inFlight[tile] {
            return try await running.value
        }
        if let failure = failures[tile], now().timeIntervalSince(failure.date) < retryInterval {
            throw BuildingSourceError.unavailable(failure.message)
        }
        let cache = self.cache
        let download = self.download
        let task = Task<[Building], Error> {
            let isDownloaded = try await cache.isDownloaded(tile)
            if !isDownloaded {
                guard let download else {
                    throw BuildingSourceError.unavailable("No building data for tile \(tile)")
                }
                let downloaded = try await download(tile.boundingBox)
                try await cache.store(downloaded, downloadedTiles: [tile])
            }
            return try await cache.buildings(in: tile.worldRect)
        }
        inFlight[tile] = task
        defer { inFlight[tile] = nil }
        do {
            let buildings = try await task.value
            failures[tile] = nil
            memory[tile] = buildings
            touch(tile)
            return buildings
        } catch {
            failures[tile] = (now(), String(describing: error))
            throw error
        }
    }

    private func touch(_ tile: TileKey) {
        recentlyUsed.removeAll { $0 == tile }
        recentlyUsed.append(tile)
        while recentlyUsed.count > memoryLimit {
            memory[recentlyUsed.removeFirst()] = nil
        }
    }
}

/// A volatile `BuildingCache` (tests, previews).
public actor InMemoryBuildingCache: BuildingCache {
    private var byID: [Int64: Building] = [:]
    private var downloaded: Set<TileKey> = []

    public init(_ buildings: [Building] = [], downloadedTiles: Set<TileKey> = []) {
        for building in buildings { byID[building.id] = building }
        downloaded = downloadedTiles
    }

    public func buildings(in rect: WorldRect) -> [Building] {
        byID.values.filter { $0.bounds.intersects(rect) }.sorted { $0.id < $1.id }
    }

    public func isDownloaded(_ tile: TileKey) -> Bool { downloaded.contains(tile) }

    public func store(_ buildings: [Building], downloadedTiles tiles: [TileKey]) {
        for building in buildings { byID[building.id] = building }
        downloaded.formUnion(tiles)
    }
}
