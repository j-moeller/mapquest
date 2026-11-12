import Foundation
import MapQuestCore

/// The demo explorer (see Tools/berlin/make_demo_data.py). City data: `Cities`.
enum BerlinData {
    static let demoProfileID = "demo"

    /// The view-only profile holding the demo explorer's data.
    static var demoProfile: DataProfile {
        DataProfile(
            descriptor: DataSourceDescriptor(
                id: demoProfileID, displayName: "Demo explorer", kind: .localDatabase(path: "demo.sqlite") // not localized: stored; shown as `DataProfile.name`
            ),
            recordsLocations: false
        )
    }

    /// The demo explorer's 1 Hz track (walks and weekday commutes, September to
    /// October 2026, and a day trip to Braunschweig; Tools/berlin/make_demo_data.py).
    static func demoTrack(bundle: Bundle = .main) throws -> [TrackPoint] {
        guard let url = bundle.url(forResource: "demo-track", withExtension: "mqtrack") else { return [] }
        return try TrackCodec.decode(Data(contentsOf: url))
    }
}
