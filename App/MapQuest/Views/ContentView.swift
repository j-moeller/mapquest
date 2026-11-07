import SwiftUI

/// 2D map (MapKit) or 3D scene (SceneKit).
enum MapMode: String, CaseIterable, Identifiable {
    case twoD = "2D"
    case threeD = "3D"

    var id: String { rawValue }
}

/// The main screen: the map with status and controls on top.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @State private var showsSettings = false
    @AppStorage("ContentView.mode") private var mode: MapMode = .twoD

    var body: some View {
        ZStack(alignment: .top) {
            switch mode {
            case .twoD:
                FogMapView(
                    snapshot: model.state(model.selectedLayer).snapshot,
                    version: model.state(model.selectedLayer).version,
                    changedTiles: model.state(model.selectedLayer).changedTiles,
                    playArea: model.playArea
                )
                .ignoresSafeArea()
            case .threeD:
                Map3DScreen()
            }

            VStack(spacing: 8) {
                HStack {
                    Picker("Map", selection: $mode) {
                        ForEach(MapMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
                PermissionBanner()
                Spacer()
                // The 3D scene always shows the line-of-sight layer.
                StatusPanel(showsSettings: $showsSettings, fixedLayer: mode == .threeD ? .lineOfSight : nil)
            }
            .padding()
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .alert("MapQuest", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Discovery statistics and the tracking switch.
struct StatusPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @Binding var showsSettings: Bool
    /// Shows this layer's statistics without a layer picker (3D mode).
    var fixedLayer: MapLayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.profile.name, systemImage: model.profile.recordsLocations ? "person.fill" : "person.2.fill")
                    .font(.headline)
                Spacer()
                if model.isBusy { ProgressView() }
                Toggle("Tracking", isOn: Binding(
                    get: { tracker.isTrackingEnabled },
                    set: { tracker.isTrackingEnabled = $0 }
                ))
                .labelsHidden()
                .disabled(!tracker.isAuthorized || !model.profile.recordsLocations)
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                }
                .accessibilityLabel("Settings")
            }
            if fixedLayer == nil {
                Picker("Discovery", selection: $model.selectedLayer) {
                    ForEach(MapLayer.allCases) { layer in
                        Text(layer.title).tag(layer)
                    }
                }
                .pickerStyle(.segmented)
            }
            let shown = fixedLayer ?? model.selectedLayer
            let layer = model.state(shown)
            HStack(spacing: 16) {
                Statistic(value: Formatters.area(layer.discoveredSquareMeters), label: "discovered")
                if let fraction = model.playAreaFraction(shown) {
                    Statistic(value: Formatters.percent(fraction), label: "of \(model.playArea.name)")
                }
                Statistic(value: "\(layer.regionCount)", label: layer.regionCount == 1 ? "region" : "regions")
                Statistic(value: "\(model.sampleCount)", label: "positions")
            }
            if model.staleLayers.contains(shown) {
                Label("Some positions are missing in this layer (no building data). Rebuild it in Settings when online.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !model.lastOutcome.isEmpty {
                Text(model.lastOutcome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct Statistic: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

enum Formatters {
    static func area(_ squareMeters: Double) -> String {
        if squareMeters >= 100_000 {
            return String(format: "%.2f km²", squareMeters / 1_000_000)
        }
        return String(format: "%.0f m²", squareMeters)
    }

    static func percent(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.001 {
            return "<0.1 %"
        }
        return String(format: "%.1f %%", fraction * 100)
    }
}
