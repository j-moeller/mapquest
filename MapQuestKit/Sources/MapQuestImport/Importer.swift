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
}
