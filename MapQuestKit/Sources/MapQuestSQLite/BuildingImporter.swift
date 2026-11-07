import Foundation
import MapQuestCore

/// Imports building outlines into a `SQLiteBuildingStore`, e.g. to build the
/// bundled Berlin database from an OpenStreetMap extract
/// (see Tools/berlin/extract_buildings.py and docs/03-berlin-data.md).
public enum BuildingImporter {
    public struct Report: Sendable, CustomStringConvertible {
        public var buildings = 0
        public var heightSources: [Building.HeightSource: Int] = [:]
        public var skippedLines = 0
        public var markedTiles = 0

        public init() {}

        public var description: String {
            let sources = [Building.HeightSource.tagged, .levels, .estimated].map { source in
                let count = heightSources[source] ?? 0
                let share = buildings > 0 ? Double(count) / Double(buildings) * 100 : 0
                return "\(source): \(count) (\(String(format: "%.1f", share)) %)"
            }
            return "\(buildings) buildings – heights " + sources.joined(separator: ", ")
                + "; \(skippedLines) skipped lines; \(markedTiles) tiles marked complete"
        }
    }

    /// Imports Overpass-style JSON elements, one per line (JSON Lines).
    public static func importOverpassLines(_ data: Data, into store: SQLiteBuildingStore, batchSize: Int = 5_000) async throws -> Report {
        var report = Report()
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        var start = 0
        while start < lines.count {
            let batch = lines[start..<min(start + batchSize, lines.count)]
            start += batchSize
            let buildings: [Building]
            if let parsed = try? OverpassBuildingParser.buildings(from: wrap(Array(batch))) {
                buildings = parsed
            } else {
                // Fall back to line-by-line parsing and skip broken lines.
                var parsed: [Building] = []
                for line in batch {
                    if let one = try? OverpassBuildingParser.buildings(from: wrap([line])) {
                        parsed += one
                    } else {
                        report.skippedLines += 1
                    }
                }
                buildings = parsed
            }
            try await store.store(buildings, downloadedTiles: [])
            report.buildings += buildings.count
            for building in buildings {
                report.heightSources[building.heightSource, default: 0] += 1
            }
        }
        return report
    }

    /// Marks every tile that lies completely inside `area` as downloaded, so the
    /// app never queries Overpass for it. Tiles crossing the border stay
    /// unmarked and are completed on demand.
    public static func markTilesComplete(inside area: [WorldPolygon], zoom: Int = 14, in store: SQLiteBuildingStore) async throws -> Int {
        guard let bounds = area.bounds else { return 0 }
        var complete: [TileKey] = []
        for tile in TileRange(covering: bounds, zoom: zoom) {
            let rect = tile.worldRect
            if PolygonOps.difference([PolygonOps.rectangle(rect)], area).isEmpty {
                complete.append(tile)
            }
        }
        try await store.store([], downloadedTiles: complete)
        return complete.count
    }

    private static func wrap(_ lines: [Data.SubSequence]) -> Data {
        var data = Data("{\"elements\":[".utf8)
        for (index, line) in lines.enumerated() {
            if index > 0 { data.append(UInt8(ascii: ",")) }
            data.append(contentsOf: line)
        }
        data.append(contentsOf: Array("]}".utf8))
        return data
    }
}
