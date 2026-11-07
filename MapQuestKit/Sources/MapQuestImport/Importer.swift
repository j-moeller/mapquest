import Foundation
import MapQuestCore
import MapQuestSQLite

/// Command-line tool to build MapQuest's building database.
///
///     swift run -c release mapquest-import buildings --output berlin-buildings.sqlite \
///         --complete-inside App/MapQuest/Resources/Berlin/berlin-boundary.geojson buildings.jsonl
@main
struct Importer {
    static let usage = """
    usage: mapquest-import buildings --output <database.sqlite> [--complete-inside <area.geojson>] [--source <text>] <buildings.jsonl>...
           mapquest-import viewshed --database <database.sqlite> <label>@<lat>,<lon>[,<altitude>]...
    """

    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        if arguments.first == "viewshed" {
            try await viewshed(Array(arguments.dropFirst()))
            return
        }
        guard arguments.first == "buildings" else {
            print(usage)
            exit(2)
        }
        var output: String?
        var area: String?
        var source = "OpenStreetMap contributors (ODbL)"
        var inputs: [String] = []
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output": output = iterator.next()
            case "--complete-inside": area = iterator.next()
            case "--source": source = iterator.next() ?? source
            default: inputs.append(argument)
            }
        }
        guard let output, !inputs.isEmpty else {
            print(usage)
            exit(2)
        }
        let store = try SQLiteBuildingStore(fileURL: URL(fileURLWithPath: output))
        var report = BuildingImporter.Report()
        for input in inputs {
            let part = try await BuildingImporter.importOverpassLines(Data(contentsOf: URL(fileURLWithPath: input)), into: store)
            report.buildings += part.buildings
            report.skippedLines += part.skippedLines
            report.heightSources.merge(part.heightSources, uniquingKeysWith: +)
            print("\(input): \(part)")
        }
        if let area {
            let polygons = try GeoJSON.playArea(named: "area", from: Data(contentsOf: URL(fileURLWithPath: area))).polygons
            report.markedTiles = try await BuildingImporter.markTilesComplete(inside: polygons, in: store)
        }
        try await store.setMetadata("source", value: source)
        try await store.setMetadata("imported_at", value: ISO8601DateFormatter().string(from: Date()))
        try await store.compact()
        let total = try await store.buildingCount()
        let size = (try? FileManager.default.attributesOfItem(atPath: output)[.size] as? Int) ?? 0
        print("total: \(report)")
        print("database: \(output), \(total) buildings, \(String(format: "%.1f", Double(size) / 1_048_576)) MB")
    }

    /// Computes line-of-sight viewsheds at given places against a building database
    /// and prints what they reveal and how long they take (a real-data check of the 3D layer).
    static func viewshed(_ arguments: [String]) async throws {
        var database: String?
        var places: [(label: String, sample: LocationSample)] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument == "--database" {
                database = iterator.next()
                continue
            }
            let parts = argument.split(separator: "@", maxSplits: 1).map(String.init)
            let numbers = (parts.last ?? "").split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2, numbers.count >= 2 else {
                print(usage)
                exit(2)
            }
            let hasAltitude = numbers.count >= 3
            places.append((parts[0], LocationSample(
                latitude: numbers[0], longitude: numbers[1], altitude: hasAltitude ? numbers[2] : 36,
                horizontalAccuracy: 5, verticalAccuracy: hasAltitude ? 5 : -1, timestamp: Date()
            )))
        }
        guard let database else {
            print(usage)
            exit(2)
        }
        let store = try SQLiteBuildingStore(fileURL: URL(fileURLWithPath: database))
        let model = ViewshedDiscoveryModel(buildings: CachingBuildingSource(cache: store, download: nil))
        for (label, sample) in places {
            let start = Date()
            let result = try await model.viewshed(for: sample)
            let elapsed = Date().timeIntervalSince(start) * 1_000
            let area = result.polygons.areaSquareMeters
            let vertices = result.polygons.reduce(0) { $0 + $1.vertexCount }
            print(String(
                format: "%@: eye %.1f m, sight %.0f m, %d buildings seen, %.0f m² visible (%.1f %% of the view disk), %d polygons / %d vertices, %.0f ms",
                label, result.eyeHeight, result.viewDistance, result.seenBuildingIDs.count, area,
                area / (Double.pi * result.viewDistance * result.viewDistance) * 100,
                result.polygons.count, vertices, elapsed
            ))
        }
    }
}
