import Foundation
import MapQuestCore

/// Tunable parameters for testing on the device (Settings › Debug).
///
/// Rendering and recording parameters apply immediately. Discovery parameters
/// (radius, line of sight, terrain) define the layer: changing them switches to
/// another layer, which is rebuilt from the stored positions if it does not exist.
struct DebugSettings: Codable, Equatable {
    // Rendering
    var fogOpacity: Double = 0.58

    // 2D discovery
    var radius: Double = 50

    // 3D discovery
    var rayCount: Int = 720
    var baseDistance: Double = 150
    var distancePerMeterOfHeight: Double = 15
    var maximumDistance: Double = 2_000
    var elevatedThreshold: Double = 8
    var usesTerrain: Bool = true

    // Recording
    var minimumNewAreaPercent: Double = 10
    var minimumMovement: Double = 5

    // Testing
    var placesPositionsOnLongPress: Bool = false
    var testEyeHeight: Double = 1.7
    var showsEvaluation: Bool = false

    static let defaults = DebugSettings()
    private static let key = "DebugSettings"

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
        return configuration
    }

    var recordingPolicy: RecordingPolicy {
        RecordingPolicy(minimumNewAreaFraction: minimumNewAreaPercent / 100, minimumMovement: minimumMovement)
    }

    /// Whether switching from `other` to `self` changes a discovery layer.
    func changesLayers(comparedTo other: DebugSettings) -> Bool {
        radius != other.radius || viewshedConfiguration != other.viewshedConfiguration || usesTerrain != other.usesTerrain
    }
}
