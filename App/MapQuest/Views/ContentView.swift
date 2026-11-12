import MapQuestCore
import SwiftUI

/// 2D map (MapKit) or 3D scene (SceneKit).
enum MapMode: String, CaseIterable, Identifiable {
    case twoD = "2D"
    case threeD = "3D"

    var id: String { rawValue }
}

/// The main screen: only the map, a menu button, a note when the map shows
/// something other than everything discovered, and at the bottom the captures
/// and the tracking button. How the map is shown, the statistics and all
/// settings are in the menu.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @EnvironmentObject private var captures: CaptureModel
    @State private var showsSettings = false
    @State private var showsMapView = false
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
                    ViewChip(mode: mode) { showsMapView = true }
                    Spacer(minLength: 8)
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.title3.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .topTrailing) {
                                // A layer misses positions: Discovered area in the menu rebuilds it.
                                if !model.staleLayers.isEmpty {
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 9, height: 9)
                                        .offset(x: 2, y: -2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Menu")
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
                BottomBar()
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
        .sheet(isPresented: $showsMapView) {
            NavigationStack {
                MapViewSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsMapView = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
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

/// What the map shows, when it is not everything discovered (fog of war,
/// radius, all time): e.g. "Heatmap · Week 45, 2026". Tapping it opens the map view settings.
struct ViewChip: View {
    @EnvironmentObject private var model: AppModel
    let mode: MapMode
    let onTap: () -> Void

    var body: some View {
        let parts = description
        if !parts.isEmpty {
            Button(action: onTap) {
                Label(parts.joined(separator: " · "), systemImage: "slider.horizontal.below.rectangle")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the map view settings")
        }
    }

    private var description: [String] {
        var parts: [String] = []
        if mode == .twoD {
            if model.aggregate == .heatmap { parts.append(MapAggregate.heatmap.title) }
            if model.selectedLayer == .lineOfSight { parts.append(MapLayer.lineOfSight.title) }
        }
        if let period = model.currentPeriod { parts.append(period.title()) }
        return parts
    }
}

/// The bottom of the main screen: the number of captures (opens the sights and
/// achievements) and the tracking button.
struct BottomBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var captures: CaptureModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                captures.showsList = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trophy.fill")
                        .font(.title2)
                        .foregroundStyle(Color.captureGold)
                        .overlay(alignment: .topTrailing) {
                            // Entries not read yet.
                            if captures.unreadEntryCount > 0 {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 9, height: 9)
                                    .offset(x: 4, y: -2)
                            }
                        }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(captures.capturedCount)")
                            .font(.title3.monospacedDigit().bold())
                        Text(captures.capturedCount == 1 ? "capture" : "captures")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(captures.capturedCount) of \(captures.gameSightCount) sights captured")
            .accessibilityHint("Opens the sights and achievements")
            Spacer(minLength: 8)
            if model.isBusy || model.progress != nil || model.viewProgress != nil || model.dataRefresh != nil {
                ProgressView()
            }
            TrackingButton()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Starts and pauses recording positions.
struct TrackingButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker

    var body: some View {
        let on = tracker.isTrackingEnabled
        let available = tracker.isAuthorized && model.profile.recordsLocations
        Button {
            tracker.isTrackingEnabled.toggle()
        } label: {
            Label(title(on: on), systemImage: on ? "location.fill" : "location")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(on ? Color.green : Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
        .accessibilityLabel(on ? "Tracking is on" : "Start tracking")
        .accessibilityHint(on ? "Pauses recording your positions" : "Records your positions and lifts the fog where you go")
    }

    private func title(on: Bool) -> String {
        if !model.profile.recordsLocations { return "View only" }
        return on ? "Tracking" : "Start tracking"
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
