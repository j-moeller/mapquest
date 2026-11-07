import SwiftUI

/// The main screen: the map with status and controls on top.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @State private var showsSettings = false

    var body: some View {
        ZStack(alignment: .top) {
            let layer = model.state(model.selectedLayer)
            FogMapView(
                snapshot: layer.snapshot,
                version: layer.version,
                changedTiles: layer.changedTiles,
                playArea: model.playArea
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                PermissionBanner()
                Spacer()
                StatusPanel(showsSettings: $showsSettings)
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
            Picker("Discovery", selection: $model.selectedLayer) {
                ForEach(MapLayer.allCases) { layer in
                    Text(layer.title).tag(layer)
                }
            }
            .pickerStyle(.segmented)
            let layer = model.state(model.selectedLayer)
            HStack(spacing: 16) {
                Statistic(value: Formatters.area(layer.discoveredSquareMeters), label: "discovered")
                if let fraction = model.playAreaFraction(model.selectedLayer) {
                    Statistic(value: Formatters.percent(fraction), label: "of \(model.playArea.name)")
                }
                Statistic(value: "\(layer.regionCount)", label: layer.regionCount == 1 ? "region" : "regions")
                Statistic(value: "\(model.sampleCount)", label: "positions")
            }
            if model.staleLayers.contains(model.selectedLayer) {
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
