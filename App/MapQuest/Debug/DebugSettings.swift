import Foundation
import MapQuestCore

/// Tunable parameters for testing on the device (Settings › Debug).
///
/// Rendering and recording parameters apply immediately. Discovery parameters
/// (radius, line of sight, terrain) define the layer: changing them switches to
/// another layer, which is rebuilt from the stored positions if it does not exist.
struct DebugSettings: Codable, Equatable {
    /// Bumped when defaults change in a way stored settings must follow (see `init(from:)`).
    static let currentVersion = 3
    var version = DebugSettings.currentVersion

    // Rendering
    var fogOpacity: Double = 0.9

    // 2D discovery
    var radius: Double = 50

    // 3D discovery
    var rayCount: Int = 720
    var baseDistance: Double = 150
    var distancePerMeterOfHeight: Double = 15
    var maximumDistance: Double = 2_000
    var elevatedThreshold: Double = 8
    var usesTerrain: Bool = true

    // Building data
    /// Download building data from OpenStreetMap where it is missing. Off: the
    /// line-of-sight layer uses the radius circle there until data is downloaded.
    var downloadsBuildings: Bool = true

    // Recording
    var minimumNewAreaPercent: Double = 10
    /// Sampling spacing (`CoverageSampler`): about one fix per this many metres is evaluated.
    var minimumMovement: Double = 10

    // Testing
    var placesPositionsOnLongPress: Bool = false
    var testEyeHeight: Double = 1.7
    var showsEvaluation: Bool = false

    static let defaults = DebugSettings()
    private static let key = "DebugSettings"

    enum CodingKeys: String, CodingKey {
        case version, fogOpacity, radius, rayCount, baseDistance, distancePerMeterOfHeight, maximumDistance
        case elevatedThreshold, usesTerrain, downloadsBuildings, minimumNewAreaPercent, minimumMovement
        case placesPositionsOnLongPress, testEyeHeight, showsEvaluation
    }

    init() {}

    /// Missing keys (settings stored by older versions) keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = DebugSettings()
        fogOpacity = value(.fogOpacity, d.fogOpacity)
        radius = value(.radius, d.radius)
        rayCount = value(.rayCount, d.rayCount)
        baseDistance = value(.baseDistance, d.baseDistance)
        distancePerMeterOfHeight = value(.distancePerMeterOfHeight, d.distancePerMeterOfHeight)
        maximumDistance = value(.maximumDistance, d.maximumDistance)
        elevatedThreshold = value(.elevatedThreshold, d.elevatedThreshold)
        usesTerrain = value(.usesTerrain, d.usesTerrain)
        downloadsBuildings = value(.downloadsBuildings, d.downloadsBuildings)
        minimumNewAreaPercent = value(.minimumNewAreaPercent, d.minimumNewAreaPercent)
        minimumMovement = value(.minimumMovement, d.minimumMovement)
        placesPositionsOnLongPress = value(.placesPositionsOnLongPress, d.placesPositionsOnLongPress)
        testEyeHeight = value(.testEyeHeight, d.testEyeHeight)
        showsEvaluation = value(.showsEvaluation, d.showsEvaluation)
        // Version 2: the fog became 90 % opaque (was 58 %).
        let stored = value(.version, 1)
        if stored < 2 { fogOpacity = d.fogOpacity }
        // Version 3: the 1 Hz track; fixes are sampled about every 10 m (was: every 5 m).
        if stored < 3 { minimumMovement = d.minimumMovement }
        version = Self.currentVersion
    }

    static func load(from defaults: UserDefaults = .standard) -> DebugSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(DebugSettings.self, from: data)
        else { return DebugSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    var viewshedConfiguration: ViewshedConfiguration {
        var configuration = ViewshedConfiguration()
        configuration.rayCount = rayCount
        configuration.baseDistance = baseDistance
        configuration.distancePerMeterOfHeight = distancePerMeterOfHeight
        configuration.maximumDistance = max(maximumDistance, baseDistance)
        configuration.elevatedThreshold = elevatedThreshold
        // Where no building data is available, the line of sight uses the 2D circle.
        configuration.fallbackRadius = radius
        return configuration
    }

    var recordingPolicy: RecordingPolicy {
        RecordingPolicy(minimumNewAreaFraction: minimumNewAreaPercent / 100, samplingSpacing: max(minimumMovement, 1))
    }

    /// Whether switching from `other` to `self` changes a discovery layer.
    func changesLayers(comparedTo other: DebugSettings) -> Bool {
        radius != other.radius || viewshedConfiguration != other.viewshedConfiguration || usesTerrain != other.usesTerrain
    }
}
