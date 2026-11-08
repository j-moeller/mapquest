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

/// Persistent storage for downloaded buildings, organised by data tiles.
public protocol BuildingCache: Sendable {
    func buildings(in rect: WorldRect) async throws -> [Building]
    /// The version of a data tile's buildings, or `nil` if the tile has no data.
    func version(of tile: TileKey) async throws -> String?
    /// Stores buildings and marks `tiles` as downloaded (atomically).
    func store(_ buildings: [Building], downloadedTiles tiles: [TileKey]) async throws
}

public extension BuildingCache {
    func isDownloaded(_ tile: TileKey) async throws -> Bool {
        try await version(of: tile) != nil
    }
}

/// Serves buildings from a persistent cache and downloads missing areas on
/// demand, one data tile (zoom 14, ≈ 1.5 km in Berlin) at a time. Recently used
/// tiles are kept in memory, so repeated viewshed computations do not hit the
/// disk. After a failed download a tile is not retried for `retryInterval`, so
/// that being offline does not stall the processing of every position fix.
/// With `downloadsAutomatically` off, only explicit requests
/// (`dataVersions(of:fetchingMissing: true)`) download; outside `downloadRegion`
/// nothing is downloaded at all (those tiles have no data: the line-of-sight
/// layer uses the default map there). Every successful download is reported to
/// `onDataChange` (cache invalidation).
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
    private var onDataChange: (@Sendable (Set<TileKey>) -> Void)?
    public private(set) var downloadsAutomatically: Bool
    /// Data tiles that may be downloaded (`nil`: all).
    private var downloadRegion: (@Sendable (TileKey) -> Bool)?

    /// - Parameters:
    ///   - download: Fetches buildings for a box; `nil` makes the source offline-only.
    public init(
        cache: any BuildingCache,
        download: Download?,
        downloadsAutomatically: Bool = true,
        downloadZoom: Int = DataGrid.zoom,
        memoryLimit: Int = 24,
        retryInterval: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = cache
        self.download = download
        self.downloadsAutomatically = downloadsAutomatically
        self.downloadZoom = downloadZoom
        self.memoryLimit = memoryLimit
        self.retryInterval = retryInterval
        self.now = now
    }

    public func setDownloadsAutomatically(_ enabled: Bool) {
        downloadsAutomatically = enabled
    }

    /// Restricts downloads to the data tiles for which `region` is true (`nil`: everywhere).
    public func setDownloadRegion(_ region: (@Sendable (TileKey) -> Bool)?) {
        downloadRegion = region
    }

    /// Whether a data tile may be downloaded at all.
    public func mayDownload(_ tile: TileKey) -> Bool {
        download != nil && (downloadRegion?(tile) ?? true)
    }

    /// Called with the data tiles whose data changed (after downloads).
    public func setOnDataChange(_ handler: (@Sendable (Set<TileKey>) -> Void)?) {
        onDataChange = handler
    }

    public func buildings(in rect: WorldRect) async throws -> [Building] {
        var seen = Set<Int64>()
        var result: [Building] = []
        for tile in TileRange(covering: rect, zoom: downloadZoom) {
            for building in try await tileBuildings(tile, mayDownload: downloadsAutomatically)
            where building.bounds.intersects(rect) && seen.insert(building.id).inserted {
                result.append(building)
            }
        }
        return result
    }

    public func coverage(in rect: WorldRect) async -> BuildingCoverage {
        var seen = Set<Int64>()
        var buildings: [Building] = []
        var versions: DataVersions = [:]
        for tile in TileRange(covering: rect, zoom: downloadZoom) {
            guard let tileBuildings = try? await tileBuildings(tile, mayDownload: downloadsAutomatically),
                  let version = try? await cache.version(of: tile)
            else {
                versions[tile] = DataGrid.noData
                continue
            }
            versions[tile] = version
            for building in tileBuildings where building.bounds.intersects(rect) && seen.insert(building.id).inserted {
                buildings.append(building)
            }
        }
        return BuildingCoverage(buildings: buildings, versions: versions)
    }

    public func dataVersions(of tiles: [TileKey], fetchingMissing: Bool) async -> DataVersions {
        var versions: DataVersions = [:]
        for tile in tiles {
            var version = (try? await cache.version(of: tile)) ?? nil
            if version == nil, fetchingMissing, (try? await tileBuildings(tile, mayDownload: true, ignoringBackoff: true)) != nil {
                version = (try? await cache.version(of: tile)) ?? nil
            }
            versions[tile] = version ?? DataGrid.noData
        }
        return versions
    }

    /// - Parameters:
    ///   - mayDownload: whether a missing tile may be downloaded.
    ///   - ignoringBackoff: retry a failed download now (explicit requests).
    private func tileBuildings(_ tile: TileKey, mayDownload: Bool, ignoringBackoff: Bool = false) async throws -> [Building] {
        if let cached = memory[tile] {
            touch(tile)
            return cached
        }
        if let running = inFlight[tile] {
            return try await running.value
        }
        let download = mayDownload && (downloadRegion?(tile) ?? true) ? self.download : nil
        if download != nil, !ignoringBackoff, let failure = failures[tile], now().timeIntervalSince(failure.date) < retryInterval {
            throw BuildingSourceError.unavailable(failure.message)
        }
        let cache = self.cache
        // Returns the tile's buildings and whether they were downloaded just now.
        let task = Task<([Building], Bool), Error> {
            if try await cache.isDownloaded(tile) {
                return (try await cache.buildings(in: tile.worldRect), false)
            }
            guard let download else {
                throw BuildingSourceError.unavailable("No building data for tile \(tile)")
            }
            let downloaded = try await download(tile.boundingBox)
            try await cache.store(downloaded, downloadedTiles: [tile])
            return (try await cache.buildings(in: tile.worldRect), true)
        }
        inFlight[tile] = Task { try await task.value.0 }
        defer { inFlight[tile] = nil }
        do {
            let (buildings, downloadedNow) = try await task.value
            failures[tile] = nil
            memory[tile] = buildings
            touch(tile)
            if downloadedNow { onDataChange?([tile]) }
            return buildings
        } catch {
            if download != nil { failures[tile] = (now(), String(describing: error)) }
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

/// A volatile `BuildingCache` (tests, previews). Every `store` call creates a new
/// version (`memory:<n>`) of the stored tiles.
public actor InMemoryBuildingCache: BuildingCache {
    private var byID: [Int64: Building] = [:]
    private var versions: [TileKey: String] = [:]
    private var counter = 0

    public init(_ buildings: [Building] = [], downloadedTiles: Set<TileKey> = []) {
        for building in buildings { byID[building.id] = building }
        for tile in downloadedTiles { versions[tile] = "memory:0" }
    }

    public func buildings(in rect: WorldRect) -> [Building] {
        byID.values.filter { $0.bounds.intersects(rect) }.sorted { $0.id < $1.id }
    }

    public func version(of tile: TileKey) -> String? { versions[tile] }

    public func store(_ buildings: [Building], downloadedTiles tiles: [TileKey]) {
        for building in buildings { byID[building.id] = building }
        counter += 1
        for tile in tiles { versions[tile] = "memory:\(counter)" }
    }
}

/// Several building datasets side by side (e.g. one bundled database per city):
/// lookups combine them, a tile's version comes from the first dataset that has
/// it. Read-only: `store` writes into the first dataset.
public struct CompositeBuildingCache: BuildingCache {
    public let caches: [any BuildingCache]

    public init(_ caches: [any BuildingCache]) {
        self.caches = caches
    }

    public func buildings(in rect: WorldRect) async throws -> [Building] {
        var seen = Set<Int64>()
        var result: [Building] = []
        for cache in caches {
            for building in try await cache.buildings(in: rect) where seen.insert(building.id).inserted {
                result.append(building)
            }
        }
        return result
    }

    public func version(of tile: TileKey) async throws -> String? {
        for cache in caches {
            if let version = try await cache.version(of: tile) { return version }
        }
        return nil
    }

    public func store(_ buildings: [Building], downloadedTiles tiles: [TileKey]) async throws {
        try await caches.first?.store(buildings, downloadedTiles: tiles)
    }
}

/// Combines a prepared base dataset (e.g. the bundled Berlin database, which may
/// first have to be unpacked) with an overlay cache for downloads. Lookups use
/// both; downloaded buildings go into the overlay. The base is prepared once,
/// in the background, on first use. Where the base has a data tile, its version
/// wins (prefixed `bundle:`); otherwise the overlay's (prefixed `download:`).
public actor LayeredBuildingCache: BuildingCache {
    private let base: Task<(any BuildingCache)?, Never>
    private let overlay: any BuildingCache

    public init(overlay: any BuildingCache, base prepare: @escaping @Sendable () async -> (any BuildingCache)?) {
        self.overlay = overlay
        self.base = Task(priority: .userInitiated) { await prepare() }
    }

    public func buildings(in rect: WorldRect) async throws -> [Building] {
        let fromBase = try await base.value?.buildings(in: rect) ?? []
        let known = Set(fromBase.map(\.id))
        let fromOverlay = try await overlay.buildings(in: rect).filter { !known.contains($0.id) }
        return fromBase + fromOverlay
    }

    public func version(of tile: TileKey) async throws -> String? {
        if let base = await base.value, let version = try await base.version(of: tile) {
            return "bundle:\(version)"
        }
        return try await overlay.version(of: tile).map { "download:\($0)" }
    }

    public func store(_ buildings: [Building], downloadedTiles tiles: [TileKey]) async throws {
        try await overlay.store(buildings, downloadedTiles: tiles)
    }
}
