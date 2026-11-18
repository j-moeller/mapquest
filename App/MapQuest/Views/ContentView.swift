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
    @EnvironmentObject private var languages: LanguageSettings
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
                    .accessibilityLabel(tr("Menu"))
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
        // Another language: the map and everything on it are built again (open sheets stay).
        .id(languages.language)
        .modifier(CaptureHooks(captures: captures))
        // What a recording brought, when it ends; a tap anywhere closes it.
        .overlay {
            if let summary = model.recordingSummary {
                RecordingSummaryView(summary: summary) { model.recordingSummary = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.recordingSummary)
        .task { await model.recordingChanged(isOn: tracker.isTrackingEnabled, captures: captures) }
        // The list shows the city you are in.
        .onReceive(tracker.$lastLocation) { location in
            guard let location else { return }
            let coordinate = GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            guard let area = model.cities.first(where: { $0.contains(coordinate) }) else { return }
            captures.follow(Cities.all.first { $0.name == area.name }?.id)
        }
        .onChange(of: tracker.isTrackingEnabled) { _, on in
            Task { await model.recordingChanged(isOn: on, captures: captures) }
        }
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
                            Button(tr("Done")) { showsMapView = false }
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

    /// Sights and stations count where you have been: the radius layer (circles around
    /// your positions), not what the line of sight revealed from afar – within about
    /// 300 m a sight shows as a question mark, covered it is discovered. (The camera
    /// does open where you can see a discovered sight: `CaptureModel.canPhotograph`.)
    private func updateCaptures() {
        captures.update(
            sourceID: model.profile.id, recordsLocations: model.profile.recordsLocations,
            snapshots: [model.state(.radius).snapshot], circleRadius: model.circleModel.radius
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
            .accessibilityHint(tr("Opens the map view settings"))
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
                        Text(Formatters.number(captures.capturedCount(in: captures.cityID)))
                            .font(.title3.monospacedDigit().bold())
                        Text(trn("capture", "captures", captures.capturedCount(in: captures.cityID)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("{0} of {1} sights captured", captures.capturedCount(in: captures.cityID),
                                   captures.gameSightCount(in: captures.cityID)))
            .accessibilityHint(tr("Opens the sights and achievements"))
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

/// Starts and stops recording: a red record dot to start; while recording, a stop
/// square with the time recorded so far.
struct TrackingButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker

    var body: some View {
        let recordsHere = model.profile.recordsLocations
        let on = tracker.isTrackingEnabled && recordsHere
        let available = tracker.isAuthorized && recordsHere
        Button {
            tracker.isTrackingEnabled.toggle()
        } label: {
            HStack(spacing: 8) {
                if !recordsHere {
                    Image(systemName: "eye")
                    Text(tr("View only"))
                } else if on {
                    Image(systemName: "stop.fill")
                    elapsed
                } else {
                    Image(systemName: "record.circle")
                        .foregroundStyle(Color.red)
                        .font(.title3.weight(.semibold))
                    Text(tr("Record"))
                }
            }
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? AnyShapeStyle(Color.red) : AnyShapeStyle(Material.thickMaterial), in: Capsule())
            .overlay {
                if !on { Capsule().strokeBorder(Color.red.opacity(0.35), lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
        .accessibilityLabel(on ? tr("Stop recording") : tr("Record"))
        .accessibilityHint(on ? tr("Stops recording your positions and shows what this recording brought")
                              : tr("Records your positions and lifts the fog where you go"))
    }

    /// "12:34" (or "1:02:03") since the recording started, every second.
    private var elapsed: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let start = model.recordingSession?.start {
                let seconds = max(0, context.date.timeIntervalSince(start))
                Text(Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                    .monospacedDigit()
            } else {
                Text(tr("Stop"))
            }
        }
    }
}
