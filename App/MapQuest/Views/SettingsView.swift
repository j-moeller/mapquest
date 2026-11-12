import CoreLocation
import MapQuestCore
import SwiftUI

/// The menu: how the map is shown and the statistics first, then recording and
/// the data source, the stored data, the developer settings and deleting.
/// Every entry opens its own page.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ContentView.mode") private var mode: MapMode = .twoD
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        page(MapViewSettingsView())
                    } label: {
                        MenuRow(title: "Map view", systemImage: "map.fill", tint: .blue, detail: mapViewDetail)
                    }
                    NavigationLink {
                        page(StatisticsView())
                    } label: {
                        MenuRow(title: "Statistics", systemImage: "chart.bar.fill", tint: .indigo,
                                detail: Formatters.area(model.state(.radius).discoveredSquareMeters))
                    }
                }

                Section {
                    NavigationLink {
                        page(RecordingSettingsView())
                    } label: {
                        MenuRow(title: "Recording", systemImage: "location.fill", tint: .green, detail: recordingDetail)
                    }
                    NavigationLink {
                        page(DataSourceView())
                    } label: {
                        MenuRow(title: "Data source", systemImage: "person.2.fill", tint: .teal, detail: model.profile.name)
                    }
                } header: {
                    Text("Recording")
                }

                Section {
                    NavigationLink {
                        page(DiscoveredAreaView())
                    } label: {
                        MenuRow(title: "Discovered area", systemImage: "square.dashed.inset.filled", tint: .orange,
                                detail: model.staleLayers.isEmpty ? nil : "Rebuild needed",
                                warns: !model.staleLayers.isEmpty)
                    }
                    NavigationLink {
                        page(BuildingDataView())
                    } label: {
                        MenuRow(title: "Building data", systemImage: "building.2.fill", tint: .brown,
                                detail: model.dataRefresh != nil ? "Updating…" : nil)
                    }
                    NavigationLink {
                        page(MapDataView())
                    } label: {
                        MenuRow(title: "Map data", systemImage: "externaldrive.fill", tint: .gray)
                    }
                } header: {
                    Text("Data")
                }

                Section {
                    Button {
                        // The panel opens over the map, so changes can be watched (and the map used) while tuning.
                        model.opensDebugPanelAfterSettings = true
                        dismiss()
                    } label: {
                        MenuRow(title: "Debug settings", systemImage: "slider.horizontal.3", tint: .purple)
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Tune radius, line of sight, fog and recording on the fly, and place test positions – in a panel over the map, which stays usable.")
                }

                Section {
                    Button("Delete all data of “\(model.profile.name)”", role: .destructive) {
                        confirmDelete = true
                    }
                    .disabled(model.isBusy)
                }
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete all positions and discoveries of “\(model.profile.name)”?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await model.deleteAllData() }
                }
            }
        }
    }

    /// A page of the menu, with Done to close the menu from there.
    private func page<Content: View>(_ content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    /// "2D · Fog · All time".
    private var mapViewDetail: String {
        var parts = [mode.rawValue]
        if mode == .twoD { parts.append(model.aggregate == .heatmap ? "Heatmap" : "Fog") }
        parts.append(model.currentPeriod?.kind.title ?? "All time")
        return parts.joined(separator: " · ")
    }

    private var recordingDetail: String {
        if !model.profile.recordsLocations { return "View only" }
        if !tracker.isAuthorized { return "Not allowed" }
        return tracker.isTrackingEnabled ? "On" : "Off"
    }

    static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using the app"
        @unknown default: return "Unknown"
        }
    }
}

/// A menu entry: a coloured icon, the title and a short value.
struct MenuRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    var detail: String?
    var warns = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: 7))
            Text(title)
            Spacer(minLength: 8)
            if let detail {
                if warns {
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Recording positions: on or off, and the location permission.
struct RecordingSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker

    var body: some View {
        Form {
            Section {
                Toggle("Record positions", isOn: Binding(
                    get: { tracker.isTrackingEnabled },
                    set: { tracker.isTrackingEnabled = $0 }
                ))
                .disabled(!tracker.isAuthorized || !model.profile.recordsLocations)
                LabeledContent("Permission", value: SettingsView.describe(tracker.authorizationStatus))
                if tracker.authorizationStatus == .authorizedWhenInUse {
                    Button("Allow background discovery") {
                        tracker.requestAlwaysAuthorization()
                    }
                }
            } footer: {
                Text(model.profile.recordsLocations
                     ? "While recording, every position (about one per second) is added to the track, compactly encoded (≈ 6 bytes per position). The positions that reveal something new also drive the fog of war. The button at the bottom of the map starts and pauses recording too."
                     : "“\(model.profile.name)” shows another user's discoveries and records nothing. Choose your own data under Data source to record.")
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Whose positions and discoveries the app shows.
struct DataSourceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(model.profiles) { profile in
                    Button {
                        Task { await model.select(profile) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .foregroundStyle(.primary)
                                Text(profile.recordsLocations ? "Records your positions" : "View only")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.id == model.profile.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
                NavigationLink("Add remote data source…") {
                    AddRemoteSourceView()
                }
            } footer: {
                Text("Location data and discovered area always travel together. Switching the data source shows another user's discoveries – the rest of the app stays the same.")
            }
        }
        .navigationTitle("Data source")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The discovered area: the layers, how they are computed, and rebuilding them.
struct DiscoveredAreaView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(MapLayer.allCases) { layer in
                    let state = model.state(layer)
                    LabeledContent(layer.title, value: "\(Formatters.area(state.discoveredSquareMeters)) in \(state.regionCount) \(state.regionCount == 1 ? "region" : "regions")")
                    if model.staleLayers.contains(layer) {
                        Label("Some positions are missing in this layer. Rebuild it.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent("Radius (2D)", value: "\(Int(model.circleModel.radius)) m around each position")
                LabeledContent("Line of sight (3D)", value: "\(model.viewshedModel.configuration.rayCount) rays, up to \(Int(model.viewshedModel.configuration.maximumDistance)) m")
            } header: {
                Text("Layers")
            } footer: {
                if !model.cities.isEmpty {
                    Text("The fog of war lifts everywhere. \(model.cities.map(\.name).joined(separator: ", ")) also have 3D building and terrain data for the line of sight; elsewhere it reveals the radius circle.")
                }
            }

            Section {
                Button("Rebuild discovered area") {
                    Task { await model.rebuildDiscoveredArea() }
                }
                .disabled(model.isBusy)
                if let progress = model.progress {
                    ProgressView(value: progress)
                }
            } footer: {
                Text("The discovered area is a cache computed from the stored positions. Rebuilding recomputes both layers from scratch; usually this is not needed – areas are recomputed automatically when building data changes.")
            }
        }
        .navigationTitle("Discovered area")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Building data for the line of sight: bundled, downloaded, missing.
struct BuildingDataView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Download automatically", isOn: Binding(
                    get: { model.debug.downloadsBuildings },
                    set: { enabled in
                        var settings = model.debug
                        settings.downloadsBuildings = enabled
                        Task { await model.applyDebugSettings(settings) }
                    }
                ))
                let data = model.buildingData
                LabeledContent("Explored areas", value: "\(data.bundled + data.downloaded + data.missing) × 1.5 km tiles")
                LabeledContent("With building data", value: "\(data.bundled) bundled, \(data.downloaded) downloaded")
                LabeledContent("Default map (no data)", value: "\(data.missing)")
                if let refresh = model.dataRefresh {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Updating \(refresh.layer.title.lowercased()) for new building data…")
                            .font(.subheadline)
                        if let fraction = refresh.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                    }
                }
                Button {
                    Task { await model.downloadMissingBuildingData() }
                } label: {
                    HStack {
                        Text("Download missing building data")
                        if model.isDownloadingBuildings {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(model.isDownloadingBuildings || data.missing == 0)
            } footer: {
                Text("Building data is bundled for the cities with 3D data and downloaded (OpenStreetMap) only around them. Where none is available (other places, offline), the line-of-sight layer uses the radius circle – the default map. When building data arrives, by download or with a newer bundled dataset, exactly the areas whose view it can change are recomputed from the stored positions.")
            }
        }
        .navigationTitle("Building data")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.checkBuildingData(fetchingMissing: false) }
    }
}

/// The cached map data (vector tiles of the base map): size and deletion.
struct MapDataView: View {
    @State private var bytes: Int?

    var body: some View {
        Form {
            Section {
                LabeledContent("Stored on this iPhone", value: bytes.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                } ?? "…")
                Button("Delete map data", role: .destructive) {
                    Task {
                        await Task.detached(priority: .userInitiated) { VectorTileStore.shared.clear() }.value
                        await measure()
                    }
                }
                .disabled((bytes ?? 0) == 0)
            } footer: {
                Text("The map is drawn on this iPhone from OpenStreetMap data (OpenFreeMap vector tiles, no labels). Every area you have looked at is kept here, compressed, and works offline; it is refreshed after 90 days and limited to 500 MB.")
            }
        }
        .navigationTitle("Map data")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
    }

    @MainActor
    private func measure() async {
        bytes = await Task.detached(priority: .utility) { VectorTileStore.shared.diskUsage() }.value
    }
}
