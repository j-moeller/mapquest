import MapQuestCore
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
    @EnvironmentObject private var captures: CaptureModel
    @State private var showsSettings = false
    @AppStorage("ContentView.mode") private var mode: MapMode = .twoD
    @StateObject private var scene3D = Scene3DController()
    @State private var debugDetent = DebugPanelDetent.small

    var body: some View {
        ZStack(alignment: .top) {
            switch mode {
            case .twoD:
                let shown = model.displayedState(model.selectedLayer)
                FogMapView(
                    snapshot: shown.snapshot,
                    identity: shown.identity,
                    version: shown.version,
                    changedTiles: shown.changedTiles,
                    aggregate: model.aggregate,
                    heatPoints: model.heatPoints,
                    cities: model.cities,
                    fogStyle: model.debug.fogStyle,
                    baseMap: model.debug.baseMap,
                    sightPins: captures.pins(showingAll: model.debug.showsAllSights),
                    stationPins: captures.stationPins(showingAll: model.debug.showsAllSights),
                    focus: captures.focus,
                    onOpenSight: { captures.openEntry($0) },
                    onLongPress: model.debug.placesPositionsOnLongPress ? { coordinate in
                        Task { await model.placeTestPosition(at: coordinate) }
                    } : nil
                )
                .ignoresSafeArea()
            case .threeD:
                Map3DScreen(controller: scene3D)
            }

            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    Picker("Map", selection: $mode) {
                        ForEach(MapMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    ViewBar(showsAggregate: mode == .twoD)
                    Spacer(minLength: 0)
                    Button {
                        model.showsDebugPanel.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 36, height: 30)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Debug settings")
                }
                PermissionBanner()
                if mode == .threeD {
                    Scene3DOverlay(controller: scene3D)
                }
                Spacer()
                if mode == .twoD {
                    // Credit for the base map (OpenStreetMap data, OpenFreeMap vector tiles).
                    Text(BaseMapStyle.attribution)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                // The 3D scene always shows the line-of-sight layer.
                StatusPanel(showsSettings: $showsSettings, fixedLayer: mode == .threeD ? .lineOfSight : nil)
            }
            .padding()
        }
        .modifier(CaptureHooks(captures: captures))
        // The capture component follows the discovered area of the selected data source.
        .task(id: captureInput) { updateCaptures() }
        .onChange(of: captures.focus) { _, focus in
            if focus != nil { mode = .twoD }
        }
        .onAppear {
            model.isShowing3D = mode == .threeD
            captures.photosAnywhere = model.debug.photosAnywhere
        }
        .onChange(of: model.debug.photosAnywhere) { _, anywhere in captures.photosAnywhere = anywhere }
        .onChange(of: mode) { _, newMode in model.isShowing3D = newMode == .threeD }
        .onChange(of: model.selectedLayer) { _, _ in
            if model.periodKind != nil { model.refreshView() }
        }
        .sheet(isPresented: $showsSettings, onDismiss: {
            if model.opensDebugPanelAfterSettings {
                model.opensDebugPanelAfterSettings = false
                debugDetent = DebugPanelDetent.small
                model.showsDebugPanel = true
            }
        }) {
            SettingsView()
        }
        .debugPanel(isPresented: $model.showsDebugPanel, detent: $debugDetent)
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

extension ContentView {
    /// Changes whenever the selected data source or its radius layer changes.
    private var captureInput: String {
        "\(model.profile.id)|\(model.state(.radius).version)"
    }

    /// Captures count where you have been: the radius layer (circles around your
    /// positions), not what the line of sight revealed from afar.
    private func updateCaptures() {
        captures.update(
            sourceID: model.profile.id, recordsLocations: model.profile.recordsLocations,
            snapshots: [model.state(.radius).snapshot]
        )
    }
}

/// Discovery statistics and the tracking switch.
struct StatusPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @Binding var showsSettings: Bool
    /// Shows this layer's statistics without a layer picker (3D mode).
    var fixedLayer: MapLayer?
    /// Collapsed, the panel only shows the header and the statistics (small screens).
    @AppStorage("StatusPanel.collapsed") private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.snappy) { collapsed.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                            .font(.caption.bold())
                        Label(model.profile.name, systemImage: model.profile.recordsLocations ? "person.fill" : "person.2.fill")
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsed ? "Show details" : "Hide details")
                Spacer(minLength: 4)
                if model.isBusy { ProgressView() }
                CaptureButton()
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
            if fixedLayer == nil && !collapsed {
                Picker("Discovery", selection: $model.selectedLayer) {
                    ForEach(MapLayer.allCases) { layer in
                        Text(layer.title).tag(layer)
                    }
                }
                .pickerStyle(.segmented)
            }
            let shown = fixedLayer ?? model.selectedLayer
            let layer = model.state(shown)
            let heatmap = model.aggregate == .heatmap && fixedLayer == nil
            if model.periodKind == nil && !heatmap {
                HStack(spacing: 12) {
                    Statistic(value: Formatters.area(layer.discoveredSquareMeters), label: "discovered")
                    if let share = model.playAreaFraction(shown) {
                        Statistic(value: Formatters.percent(share.fraction), label: "of \(share.city)")
                    }
                    Statistic(value: "\(layer.regionCount)", label: layer.regionCount == 1 ? "region" : "regions")
                    Statistic(value: "\(model.sampleCount)", label: "positions")
                }
            } else {
                // A period or the heatmap: figures from the track.
                let summary = model.viewSummary
                HStack(spacing: 12) {
                    if let area = summary?.areaSquareMeters {
                        Statistic(value: Formatters.area(area), label: "seen")
                    }
                    Statistic(value: Formatters.distance(summary?.statistics.distanceMeters ?? 0), label: "travelled")
                    Statistic(value: Formatters.duration(summary?.statistics.recordedSeconds ?? 0), label: "recorded")
                    if let days = summary?.statistics.activeDays, model.periodKind != .day {
                        Statistic(value: "\(days)", label: days == 1 ? "day" : "days")
                    }
                }
            }
            if let progress = model.viewProgress, !collapsed {
                ProgressView(value: progress) {
                    Text("Computing \(model.currentPeriod?.title() ?? "")…").font(.caption)
                }
            }
            if model.staleLayers.contains(shown) && !collapsed {
                Label("Some positions are missing in this layer. Rebuild it in Settings.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let progress = model.progress {
                ProgressView(value: progress)
            } else if let refresh = model.dataRefresh, !collapsed {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Updating \(refresh.layer.title.lowercased()) for new building data", systemImage: "building.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let fraction = refresh.fraction {
                        ProgressView(value: fraction)
                    }
                }
            }
            if let summary = model.evaluationSummary, model.debug.showsEvaluation, !collapsed {
                Text(summary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.lastOutcome.isEmpty && !collapsed {
                Text(model.lastOutcome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
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
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func distance(_ meters: Double) -> String {
        meters >= 1_000 ? String(format: "%.1f km", meters / 1_000) : String(format: "%.0f m", meters)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? String(format: "%d h %02d min", minutes / 60, minutes % 60) : "\(minutes) min"
    }

    /// "12 345 positions · 74 KB" (bytes only once something is written).
    static func track(_ summary: TrackSummary) -> String {
        let count = summary.pointCount.formatted()
        guard summary.byteCount > 0 else { return "\(count) positions" }
        return "\(count) positions · \(bytes(summary.byteCount))"
    }
}
