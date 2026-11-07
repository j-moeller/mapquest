import Foundation

/// A slippy-map tile (Web Mercator quadtree), as used by OpenStreetMap, Apple and Google maps.
///
/// Tile keys are MapQuest's portable spatial index: every store can index two
/// integers, so the same queries work in SQLite, a server database or a
/// key-value store (see docs/01-literature-review.md, §2.3).
public struct TileKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var zoom: Int
    public var x: Int
    public var y: Int

    public init(zoom: Int, x: Int, y: Int) {
        precondition((0...WebMercator.worldSizeExponent).contains(zoom), "zoom out of range")
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    /// The tile at `zoom` that contains a world point.
    public init(containing point: WorldPoint, zoom: Int) {
        let shift = Int64(WebMercator.worldSizeExponent - zoom)
        self.init(zoom: zoom, x: Int(point.x >> shift), y: Int(point.y >> shift))
    }

    /// The tile at `zoom` that contains a coordinate.
    public init(containing coordinate: GeoCoordinate, zoom: Int) {
        self.init(containing: WebMercator.project(coordinate), zoom: zoom)
    }

    /// Edge length of a tile at `zoom` in world units.
    public static func size(atZoom zoom: Int) -> Int64 {
        Int64(1) << Int64(WebMercator.worldSizeExponent - zoom)
    }

    /// The world rectangle covered by this tile (`max` is the first unit of the next tile).
    public var worldRect: WorldRect {
        let size = Self.size(atZoom: zoom)
        let minX = Int64(x) * size
        let minY = Int64(y) * size
        return WorldRect(minX: minX, minY: minY, maxX: minX + size, maxY: minY + size)
    }

    public var origin: WorldPoint { WorldPoint(x: Int64(x) * Self.size(atZoom: zoom), y: Int64(y) * Self.size(atZoom: zoom)) }

    public var boundingBox: GeoBoundingBox { WebMercator.boundingBox(for: worldRect) }

    /// Metres per world unit at the centre of this tile.
    public var metersPerUnit: Double {
        WebMercator.metersPerUnit(atWorldY: Double(worldRect.center.y))
    }

    public var description: String { "\(zoom)/\(x)/\(y)" }

    public static func < (lhs: TileKey, rhs: TileKey) -> Bool {
        (lhs.zoom, lhs.y, lhs.x) < (rhs.zoom, rhs.y, rhs.x)
    }
}

/// An inclusive rectangular range of tiles at one zoom level.
public struct TileRange: Hashable, Codable, Sendable, Sequence {
    public var zoom: Int
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int

    public init(zoom: Int, minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.zoom = zoom
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// All tiles at `zoom` intersecting a world rectangle.
    public init(covering rect: WorldRect, zoom: Int) {
        let a = TileKey(containing: WorldPoint(x: Swift.max(rect.minX, 0), y: Swift.max(rect.minY, 0)), zoom: zoom)
        let last = WebMercator.worldSize - 1
        let b = TileKey(containing: WorldPoint(x: Swift.min(rect.maxX, last), y: Swift.min(rect.maxY, last)), zoom: zoom)
        self.init(zoom: zoom, minX: a.x, minY: a.y, maxX: b.x, maxY: b.y)
    }

    /// All tiles at `zoom` intersecting a geographic bounding box.
    public init(covering box: GeoBoundingBox, zoom: Int) {
        self.init(covering: WebMercator.worldRect(for: box), zoom: zoom)
    }

    public var count: Int { Swift.max(0, maxX - minX + 1) * Swift.max(0, maxY - minY + 1) }

    public func contains(_ tile: TileKey) -> Bool {
        tile.zoom == zoom && tile.x >= minX && tile.x <= maxX && tile.y >= minY && tile.y <= maxY
    }

    public var worldRect: WorldRect {
        let size = TileKey.size(atZoom: zoom)
        return WorldRect(
            minX: Int64(minX) * size, minY: Int64(minY) * size,
            maxX: Int64(maxX + 1) * size, maxY: Int64(maxY + 1) * size
        )
    }

    public func expanded(by tiles: Int) -> TileRange {
        let last = (1 << zoom) - 1
        return TileRange(
            zoom: zoom,
            minX: Swift.max(minX - tiles, 0), minY: Swift.max(minY - tiles, 0),
            maxX: Swift.min(maxX + tiles, last), maxY: Swift.min(maxY + tiles, last)
        )
    }

    public func makeIterator() -> AnyIterator<TileKey> {
        var x = minX
        var y = minY
        return AnyIterator {
            guard y <= maxY, x <= maxX else { return nil }
            let tile = TileKey(zoom: zoom, x: x, y: y)
            x += 1
            if x > maxX {
                x = minX
                y += 1
            }
            return tile
        }
    }
}

/// The grid MapQuest uses to bucket location samples and discovered-area pieces.
public enum DiscoveryGrid {
    /// Zoom level of the storage grid: 611 m tiles at the equator, 372 m in Berlin.
    public static let zoom = 16
}
