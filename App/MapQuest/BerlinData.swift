import Foundation
import MapQuestCore

/// Bundled data for the first play area, Berlin (see Tools/berlin and docs/03-berlin-data.md).
enum BerlinData {
    static let demoProfileID = "demo"

    /// Berlin's outline with its twelve districts as subdivisions, or `nil` if the
    /// resources are missing or broken.
    static func playArea(bundle: Bundle = .main) -> PlayArea? {
        guard
            let boundaryURL = bundle.url(forResource: "berlin-boundary", withExtension: "geojson"),
            let boundaryData = try? Data(contentsOf: boundaryURL),
            var berlin = try? GeoJSON.playArea(named: "Berlin", from: boundaryData)
        else { return nil }
        if let districtsURL = bundle.url(forResource: "berlin-districts", withExtension: "geojson"),
           let districtsData = try? Data(contentsOf: districtsURL),
           let features = try? GeoJSON.polygonFeatures(from: districtsData) {
            berlin.subdivisions = features
                .map { PlayArea(name: $0.properties["name"] ?? "District", polygons: $0.polygons) }
                .sorted { $0.name < $1.name }
        }
        return berlin
    }

    /// Berlin's terrain (ATKIS DGM, ≈ 30 m grid), if bundled.
    static func terrain(bundle: Bundle = .main) -> GridTerrain? {
        guard let url = bundle.url(forResource: "berlin-terrain", withExtension: "dem"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? GridTerrain(identifier: "berlin-dgm30", data: data, fallback: FlatTerrain.berlin.elevation)
    }

    /// The view-only profile holding the demo explorer's data.
    static var demoProfile: DataProfile {
        DataProfile(
            descriptor: DataSourceDescriptor(
                id: demoProfileID, displayName: "Demo explorer", kind: .localDatabase(path: "demo.sqlite")
            ),
            recordsLocations: false
        )
    }

    /// Raw position fixes of the demo explorer (five walks in September/October 2026).
    static func demoFixes(bundle: Bundle = .main) throws -> [LocationSample] {
        guard let url = bundle.url(forResource: "demo-walks", withExtension: "json") else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LocationSample].self, from: Data(contentsOf: url))
    }
}
