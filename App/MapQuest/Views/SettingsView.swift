import CoreLocation
import MapQuestCore
import SwiftUI

/// Data-source selection, discovery maintenance and tracking settings.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
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
                } header: {
                    Text("Data source")
                } footer: {
                    Text("Location data and discovered area always travel together. Switching the data source shows another user's discoveries – the rest of the app stays the same.")
                }

                if !model.cities.isEmpty {
                    Section {
                        NavigationLink("Cities and districts") {
                            DistrictsView()
                        }
                    } footer: {
                        Text("The fog of war lifts everywhere. \(model.cities.map(\.name).joined(separator: ", ")) also have 3D building and terrain data for the line of sight; elsewhere it reveals the radius circle.")
                    }
                }

                Section {
                    LabeledContent("Track", value: Formatters.track(model.trackSummary))
                    LabeledContent("Map-changing positions", value: "\(model.sampleCount)")
                    LabeledContent("Radius (2D)", value: "\(Int(model.circleModel.radius)) m around each position")
                    LabeledContent("Line of sight (3D)", value: "\(model.viewshedModel.configuration.rayCount) rays, up to \(Int(model.viewshedModel.configuration.maximumDistance)) m")
                    ForEach(MapLayer.allCases) { layer in
                        let state = model.state(layer)
                        LabeledContent(layer.title, value: "\(Formatters.area(state.discoveredSquareMeters)) in \(state.regionCount) \(state.regionCount == 1 ? "region" : "regions")")
                    }
                    Button("Rebuild discovered area") {
                        Task { await model.rebuildDiscoveredArea() }
                    }
                    .disabled(model.isBusy)
                } header: {
                    Text("Discovery")
                } footer: {
                    Text("The discovered area is a cache computed from the stored positions. Rebuilding recomputes both layers from scratch; usually this is not needed – areas are recomputed automatically when building data changes.")
                }

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
                } header: {
                    Text("Building data")
                } footer: {
                    Text("Building data is bundled for the cities with 3D data and downloaded (OpenStreetMap) only around them. Where none is available (other places, offline), the line-of-sight layer uses the radius circle – the default map. When building data arrives, by download or with a newer bundled dataset, exactly the areas whose view it can change are recomputed from the stored positions.")
                }
                .task { await model.checkBuildingData(fetchingMissing: false) }

                MapDataSection()

                Section {
                    Toggle("Record positions", isOn: Binding(
                        get: { tracker.isTrackingEnabled },
                        set: { tracker.isTrackingEnabled = $0 }
                    ))
                    .disabled(!tracker.isAuthorized)
                    LabeledContent("Permission", value: Self.describe(tracker.authorizationStatus))
                    if tracker.authorizationStatus == .authorizedWhenInUse {
                        Button("Allow background discovery") {
                            tracker.requestAlwaysAuthorization()
                        }
                    }
                } header: {
                    Text("Tracking")
                } footer: {
                    Text("While recording, every position (about one per second) is added to the track, compactly encoded (≈ 6 bytes per position). The positions that reveal something new also drive the fog of war.")
                }

                Section {
                    Button("Debug settings") {
                        // The panel opens over the map, so changes can be watched (and the map used) while tuning.
                        model.opensDebugPanelAfterSettings = true
                        dismiss()
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Tune radius, line of sight, fog and recording on the fly, and place test positions – in a panel over the map, which stays usable. Also on the map: the slider button at the top.")
                }

                Section {
                    Button("Delete all data of “\(model.profile.name)”", role: .destructive) {
                        confirmDelete = true
                    }
                    .disabled(model.isBusy)
                }
            }
            .navigationTitle("Settings")
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

/// The cached map data (vector tiles of the base map): size and deletion.
private struct MapDataSection: View {
    @State private var bytes: Int?

    var body: some View {
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
        } header: {
            Text("Map data")
        } footer: {
            Text("The map is drawn on this iPhone from OpenStreetMap data (OpenFreeMap vector tiles, no labels). Every area you have looked at is kept here, compressed, and works offline; it is refreshed after 90 days and limited to 500 MB.")
        }
        .task { await measure() }
    }

    @MainActor
    private func measure() async {
        bytes = await Task.detached(priority: .utility) { VectorTileStore.shared.diskUsage() }.value
    }
}
