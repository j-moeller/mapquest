import Foundation
import MapQuestCore

/// Which icons the maps show (menu › Map icons): stations by system, sights by
/// category, and the question marks of sights you came near. Hidden icons are left
/// off the 2D and 3D maps only; the list of sights shows everything.
struct MapIconFilter: Codable, Equatable {
    var hiddenSystems: Set<TransitSystem> = []
    var hiddenCategories: Set<SightCategory> = []
    var hidesQuestionMarks = false

    var hiddenCount: Int { hiddenSystems.count + hiddenCategories.count + (hidesQuestionMarks ? 1 : 0) }

    /// A question mark does not give away the kind of place: only its own switch hides it.
    /// Categories a package declares go with the core category they belong to.
    func shows(_ pin: SightPin) -> Bool {
        pin.isNearby ? !hidesQuestionMarks : !hiddenCategories.contains(pin.sight.category.core)
    }

    func shows(_ station: Station) -> Bool {
        !hiddenSystems.contains(station.system)
    }

    private static let key = "MapIconFilter" // not localized

    static func load(from defaults: UserDefaults = .standard) -> MapIconFilter {
        guard let data = defaults.data(forKey: key), let filter = try? JSONDecoder().decode(MapIconFilter.self, from: data) else {
            return MapIconFilter()
        }
        return filter
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
