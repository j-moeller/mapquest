import MapQuestCore
import SwiftUI

/// Debug settings: tune rendering, discovery and recording parameters on the device.
struct DebugSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @State private var draft = DebugSettings()
    @State private var loaded = false

    private var needsApply: Bool { draft.changesLayers(comparedTo: model.debug) }

    var body: some View {
        Form {
            Section {
                ValueSlider(title: "Fog opacity", value: $draft.fogOpacity, range: 0.1...0.95, step: 0.01, format: "%.0f %%", scale: 100)
            } header: {
                Text("Map")
            } footer: {
                Text("Applies immediately.")
            }

            Section {
                ValueSlider(title: "Radius", value: $draft.radius, range: 10...200, step: 5, format: "%.0f m")
            } header: {
                Text("Radius layer (2D)")
            }

            Section {
                ValueSlider(title: "Rays", value: Binding(
                    get: { Double(draft.rayCount) }, set: { draft.rayCount = Int($0) }
                ), range: 90...2_880, step: 90, format: "%.0f")
                ValueSlider(title: "Sight at street level", value: $draft.baseDistance, range: 50...600, step: 10, format: "%.0f m")
                ValueSlider(title: "Extra sight per metre of height", value: $draft.distancePerMeterOfHeight, range: 0...50, step: 1, format: "%.0f m")
                ValueSlider(title: "Maximum sight", value: $draft.maximumDistance, range: 200...5_000, step: 100, format: "%.0f m")
                ValueSlider(title: "Height counted as street level", value: $draft.elevatedThreshold, range: 0...30, step: 1, format: "%.0f m")
                Toggle("Use Berlin terrain model", isOn: $draft.usesTerrain)
                    .disabled(model.berlinTerrain == nil)
            } header: {
                Text("Line-of-sight layer (3D)")
            } footer: {
                Text("Heights up to the threshold plus the GPS vertical accuracy count as street level. With the terrain model, hills count as high points.")
            }

            Section {
                Button(needsApply ? "Apply and rebuild layers" : "Discovery parameters unchanged") {
                    let settings = draft
                    Task { await model.applyDebugSettings(settings) }
                }
                .disabled(!needsApply || model.isBusy)
            } footer: {
                Text("Discovery parameters define the layer. Changing them switches to another layer, which is rebuilt from the stored positions (the old one stays cached).")
            }

            Section {
                ValueSlider(title: "New area to store a position", value: $draft.minimumNewAreaPercent, range: 1...50, step: 1, format: "%.0f %%")
                ValueSlider(title: "Movement before re-evaluating", value: $draft.minimumMovement, range: 0...30, step: 1, format: "%.0f m")
            } header: {
                Text("Recording")
            } footer: {
                Text("Applies immediately to new positions.")
            }

            Section {
                Toggle("Long-press the 2D map to place a position", isOn: $draft.placesPositionsOnLongPress)
                ValueSlider(title: "Eye height of test positions", value: $draft.testEyeHeight, range: 1.7...400, step: 0.5, format: "%.1f m")
                Button("Place a test position here") {
                    guard let location = tracker.lastLocation else { return }
                    Task {
                        await model.placeTestPosition(at: GeoCoordinate(
                            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude
                        ))
                    }
                }
                .disabled(tracker.lastLocation == nil || !model.profile.recordsLocations)
                Toggle("Show evaluation details", isOn: $draft.showsEvaluation)
            } header: {
                Text("Testing")
            } footer: {
                Text(model.profile.recordsLocations
                     ? "Test positions are recorded into “\(model.profile.name)” like tracked ones. Use the “Sandbox (testing)” data source to keep your own discoveries clean."
                     : "“\(model.profile.name)” is view-only: switch to a recording data source (e.g. “Sandbox (testing)”) to place test positions.")
            }

            Section {
                Button("Reset to defaults") {
                    draft = .defaults
                }
                Button("Delete unused cached layers", role: .destructive) {
                    Task { await model.deleteUnusedLayers() }
                }
                .disabled(model.isBusy)
            }
        }
        .navigationTitle("Debug")
        .onAppear {
            if !loaded {
                draft = model.debug
                loaded = true
            }
        }
        .onChange(of: draft) { _, newValue in
            // Everything except discovery parameters applies immediately.
            var immediate = model.debug
            immediate.fogOpacity = newValue.fogOpacity
            immediate.minimumNewAreaPercent = newValue.minimumNewAreaPercent
            immediate.minimumMovement = newValue.minimumMovement
            immediate.placesPositionsOnLongPress = newValue.placesPositionsOnLongPress
            immediate.testEyeHeight = newValue.testEyeHeight
            immediate.showsEvaluation = newValue.showsEvaluation
            if immediate != model.debug {
                Task { await model.applyDebugSettings(immediate) }
            }
        }
    }
}

/// A labelled slider with its current value.
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var scale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value * scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: $value, in: range, step: step)
        }
    }
}
