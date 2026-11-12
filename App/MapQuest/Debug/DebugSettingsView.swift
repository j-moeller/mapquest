import MapQuestCore
import SwiftUI

/// Debug settings: tune rendering, discovery and recording parameters on the device.
struct DebugSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @EnvironmentObject private var captures: CaptureModel
    @State private var draft = DebugSettings()
    @State private var loaded = false

    private var needsApply: Bool { draft.changesLayers(comparedTo: model.debug) }

    var body: some View {
        Form {
            Section {
                ValueSlider(title: tr("Fog opacity"), value: $draft.fogOpacity, range: 0.1...1, step: 0.01, unit: " %", scale: 100)
                ValueSlider(title: tr("Blur under the fog"), value: $draft.fogBlur, range: 0...1, step: 0.05, unit: " %", scale: 100)
                ValueSlider(title: tr("Soft fog edges"), value: $draft.fogSoftness, range: 0...40, step: 1, unit: " m")
                Picker(tr("Base map"), selection: $draft.baseMap) {
                    ForEach(BaseMapStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                Text(tr("Map"))
            } footer: {
                Text(tr("Applies immediately. The blur shows through the fog only below 100 % opacity; soft edges fade the fog out over the given width on the ground inside discovered areas. The base map is drawn without labels from OpenStreetMap data (OpenFreeMap); only city and district names are shown, above the fog."))
            }

            Section {
                ValueSlider(title: tr("Radius"), value: $draft.radius, range: 10...200, step: 5, unit: " m")
            } header: {
                Text(tr("Radius layer (2D)"))
            }

            Section {
                ValueSlider(title: tr("Rays"), value: Binding(
                    get: { Double(draft.rayCount) }, set: { draft.rayCount = Int($0) }
                ), range: 90...2_880, step: 90)
                ValueSlider(title: tr("Sight at street level"), value: $draft.baseDistance, range: 50...600, step: 10, unit: " m")
                ValueSlider(title: tr("Extra sight per metre of height"), value: $draft.distancePerMeterOfHeight, range: 0...50, step: 1, unit: " m")
                ValueSlider(title: tr("Maximum sight"), value: $draft.maximumDistance, range: 200...5_000, step: 100, unit: " m")
                ValueSlider(title: tr("Height counted as street level"), value: $draft.elevatedThreshold, range: 0...30, step: 1, unit: " m")
                Toggle(tr("Use the cities' terrain models"), isOn: $draft.usesTerrain)
                    .disabled(model.cityTerrain == nil)
                Toggle(tr("Download buildings outside the cities"), isOn: $draft.downloadsBuildingsEverywhere)
            } header: {
                Text(tr("Line-of-sight layer (3D)"))
            } footer: {
                Text(tr("Heights up to the threshold plus the GPS vertical accuracy count as street level. With the terrain model, hills count as high points. Buildings are downloaded only around the cities with 3D data; elsewhere the line of sight uses the radius circle, unless downloads outside the cities are allowed (immediate)."))
            }

            Section {
                Button(needsApply ? tr("Apply and rebuild layers") : tr("Discovery parameters unchanged")) {
                    let settings = draft
                    Task { await model.applyDebugSettings(settings) }
                }
                .disabled(!needsApply || model.isBusy)
            } footer: {
                Text(tr("Discovery parameters define the layer. Changing them switches to another layer, which is rebuilt from the stored positions (the old one stays cached)."))
            }

            Section {
                ValueSlider(title: tr("New area to store a position"), value: $draft.minimumNewAreaPercent, range: 1...50, step: 1, unit: " %")
                ValueSlider(title: tr("Sampling spacing (evaluate every …)"), value: $draft.minimumMovement, range: 1...40, step: 1, unit: " m")
            } header: {
                Text(tr("Recording"))
            } footer: {
                Text(tr("Applies immediately to new positions."))
            }

            Section {
                Toggle(tr("Long-press the 2D map to place a position"), isOn: $draft.placesPositionsOnLongPress)
                ValueSlider(title: tr("Eye height of test positions"), value: $draft.testEyeHeight, range: 1.7...400, step: 0.5, digits: 1, unit: " m")
                Button(tr("Place a test position here")) {
                    guard let location = tracker.lastLocation else { return }
                    Task {
                        await model.placeTestPosition(at: GeoCoordinate(
                            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude
                        ))
                    }
                }
                .disabled(tracker.lastLocation == nil || !model.profile.recordsLocations)
                Toggle(tr("Show evaluation details"), isOn: $draft.showsEvaluation)
                Toggle(tr("Show all sights and stations on the map"), isOn: $draft.showsAllSights)
                Toggle(tr("Photograph sights from anywhere"), isOn: $draft.photosAnywhere)
                Button(tr("Reset discovered and captured sights"), role: .destructive) {
                    captures.resetCaptures()
                }
            } header: {
                Text(tr("Testing"))
            } footer: {
                // {1}: the sandbox's name in the app's language.
                Text(model.profile.recordsLocations
                     ? tr("Test positions are recorded into “{0}” like tracked ones. Use the “{1}” data source to keep your own discoveries clean.",
                          model.profile.name, tr("Sandbox (testing)"))
                     : tr("“{0}” is view-only: switch to a recording data source (e.g. “{1}”) to place test positions.",
                          model.profile.name, tr("Sandbox (testing)")))
            }

            Section {
                Button(tr("Reset to defaults")) {
                    draft = .defaults
                }
                Button(tr("Delete unused cached layers"), role: .destructive) {
                    Task { await model.deleteUnusedLayers() }
                }
                .disabled(model.isBusy)
            }
        }
        .navigationTitle(tr("Debug"))
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
            immediate.fogBlur = newValue.fogBlur
            immediate.fogSoftness = newValue.fogSoftness
            immediate.baseMap = newValue.baseMap
            immediate.downloadsBuildingsEverywhere = newValue.downloadsBuildingsEverywhere
            immediate.minimumNewAreaPercent = newValue.minimumNewAreaPercent
            immediate.minimumMovement = newValue.minimumMovement
            immediate.placesPositionsOnLongPress = newValue.placesPositionsOnLongPress
            immediate.testEyeHeight = newValue.testEyeHeight
            immediate.showsEvaluation = newValue.showsEvaluation
            immediate.showsAllSights = newValue.showsAllSights
            immediate.photosAnywhere = newValue.photosAnywhere
            if immediate != model.debug {
                Task { await model.applyDebugSettings(immediate) }
            }
        }
    }
}

/// A labelled slider with its current value ("12 m", "1,5 m" in German).
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// Decimal places of the value shown.
    var digits = 0
    /// After the value: " m", " %" or nothing.
    var unit = ""
    var scale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(Formatters.decimal(value * scale, digits: digits) + unit)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
        }
    }
}
