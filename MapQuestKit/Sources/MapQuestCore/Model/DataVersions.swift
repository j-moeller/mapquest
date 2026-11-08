import Foundation

/// The grid in which map data is downloaded, bundled and versioned
/// (zoom 14: ≈ 1.5 × 1.5 km in Berlin). See docs/05-cache-invalidation.md.
public enum DataGrid {
    public static let zoom = 14
    /// Version of a data tile for which no data is available.
    public static let noData = "none"
}

/// Version of the map data of each data tile (zoom `DataGrid.zoom`).
public typealias DataVersions = [TileKey: String]

/// Maintains the watermarks of a layer while results are computed: the data
/// version every data tile had when the layer was made consistent with it.
///
/// The first observed version of a tile without a watermark becomes its
/// watermark. Observing a different version later means that cached results were
/// computed from different data, so the tile is *stale* and must be refreshed.
struct DataWatermarkTracker {
    private(set) var watermarks: DataVersions
    /// Watermarks set by observations (to be persisted).
    private(set) var added: DataVersions = [:]
    /// Tiles whose observed version differs from their watermark.
    private(set) var stale: Set<TileKey> = []

    init(watermarks: DataVersions) {
        self.watermarks = watermarks
    }

    mutating func observe(_ versions: DataVersions) {
        for (tile, version) in versions {
            if let watermark = watermarks[tile] {
                if watermark != version { stale.insert(tile) }
            } else {
                watermarks[tile] = version
                added[tile] = version
            }
        }
    }

    /// Sets watermarks of tiles that were not observed.
    mutating func setIfAbsent(_ versions: DataVersions) {
        for (tile, version) in versions where watermarks[tile] == nil {
            watermarks[tile] = version
            added[tile] = version
        }
    }
}
