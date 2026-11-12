import Foundation
import MapQuestCore
import MapQuestSQLite

/// A city with bundled data: outline and districts (play area), elevation model
/// and building database. Resources are named `<id>-boundary.geojson`,
/// `<id>-districts.geojson`, `<id>-terrain.dem` and `<id>-buildings.sqlite.deflate`
/// (docs/03-berlin-data.md, docs/06-braunschweig-data.md, docs/07-peine-data.md);
/// missing ones are skipped.
struct City: Hashable, Identifiable {
    let id: String
    let name: String
    /// Typical ground elevation, used where the elevation model has no data.
    let groundElevation: Double
    /// Apple Maps has photorealistic 3D buildings here (satellite imagery on 3D
    /// models): sight entries show them; elsewhere they show photos.
    var hasPhotorealistic3D = false
}

enum Cities {
    static let all = [
        City(id: "berlin", name: "Berlin", groundElevation: 35, hasPhotorealistic3D: true), // not localized: city name
        City(id: "braunschweig", name: "Braunschweig", groundElevation: 75), // not localized: city name
        City(id: "peine", name: "Peine", groundElevation: 67), // not localized: city name
    ]

    /// The outline of a city with its districts as subdivisions, if bundled.
    static func playArea(_ city: City, bundle: Bundle = .main) -> PlayArea? {
        guard
            let boundaryURL = bundle.url(forResource: "\(city.id)-boundary", withExtension: "geojson"),
            let boundaryData = try? Data(contentsOf: boundaryURL),
            var area = try? GeoJSON.playArea(named: city.name, from: boundaryData)
        else { return nil }
        if let districtsURL = bundle.url(forResource: "\(city.id)-districts", withExtension: "geojson"),
           let districtsData = try? Data(contentsOf: districtsURL),
           let features = try? GeoJSON.polygonFeatures(from: districtsData) {
            area.subdivisions = features
                .map { PlayArea(name: $0.properties["name"] ?? tr("District"), polygons: $0.polygons) }
                .sorted { $0.name < $1.name }
        }
        return area
    }

    /// The play areas of all bundled cities.
    static func playAreas(bundle: Bundle = .main) -> [PlayArea] {
        all.compactMap { playArea($0, bundle: bundle) }
    }

    /// One play area for recording: all cities together.
    static func combined(_ cities: [PlayArea]) -> PlayArea {
        switch cities.count {
        case 0: return .world
        case 1: return cities[0]
        default:
            return PlayArea(
                name: cities.map(\.name).joined(separator: " & "),
                polygons: cities.flatMap(\.polygons), subdivisions: cities
            )
        }
    }

    /// The elevation models of all bundled cities (`<id>-dgm30`), or `nil` if none.
    static func terrain(bundle: Bundle = .main) -> CompositeTerrain? {
        let grids = all.compactMap { city -> GridTerrain? in
            guard let url = bundle.url(forResource: "\(city.id)-terrain", withExtension: "dem"),
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return try? GridTerrain(identifier: "\(city.id)-dgm30", data: data, fallback: city.groundElevation)
        }
        return grids.isEmpty ? nil : CompositeTerrain(grids, fallback: FlatTerrain.berlin.elevation)
    }

    /// The bundled building databases of all cities (unpacked once). Runs off the main thread.
    static func bundledBuildings(in directory: URL, bundle: Bundle = .main) -> (any BuildingCache)? {
        let stores = all.compactMap { BundledBuildings.prepare(city: $0.id, in: directory, bundle: bundle) }
        switch stores.count {
        case 0: return nil
        case 1: return stores[0]
        default: return CompositeBuildingCache(stores)
        }
    }
}
