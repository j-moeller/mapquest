import CoreLocation
import MapQuestCore
import SwiftUI

/// The menu: how the map is shown and the statistics first, then your photos,
/// recording and the data source, the stored data, the developer settings and deleting.
/// Every entry opens its own page.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @EnvironmentObject private var languages: LanguageSettings
    @EnvironmentObject private var captures: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ContentView.mode") private var mode: MapMode = .twoD
    /// New photos of sights also go to the Photos app (on until switched off).
    @AppStorage(CaptureModel.savesToPhotosKey) private var savesToPhotos = true
    @State private var photosDenied = PhotoLibrary.isDenied
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        page(MapViewSettingsView())
                    } label: {
                        MenuRow(title: tr("Map view"), systemImage: "map.fill", tint: .blue, detail: mapViewDetail)
                    }
                    NavigationLink {
                        page(StatisticsView())
                    } label: {
                        MenuRow(title: tr("Statistics"), systemImage: "chart.bar.fill", tint: .indigo,
                                detail: Formatters.area(model.state(.radius).discoveredSquareMeters))
                    }
                }

                Section {
                    NavigationLink {
                        page(PhotoGalleryView())
                    } label: {
                        MenuRow(title: tr("All photos"), systemImage: "photo.on.rectangle", tint: .pink,
                                detail: captures.log.album.isEmpty ? nil : Formatters.number(captures.log.album.count))
                    }
                    Toggle(isOn: $savesToPhotos) {
                        MenuRow(title: tr("Save to the Photos app"), systemImage: "square.and.arrow.down.fill", tint: .pink)
                    }
                    .onChange(of: savesToPhotos) { _, on in
                        guard on else { return }
                        Task { photosDenied = !(await PhotoLibrary.requestAccess()) }
                    }
                    if savesToPhotos && photosDenied {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(tr("MapQuest may not add photos to the Photos app. Allow it in the Settings app under MapQuest › Photos."),
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                Link(tr("Open Settings"), destination: url)
                                    .font(.footnote)
                            }
                        }
                    }
                } header: {
                    Text(tr("Photos"))
                } footer: {
                    Text(tr("Every photo you take of a sight is kept in MapQuest. Switched on, it is saved to the Photos app as well, with where and when you took it."))
                }

                Section {
                    NavigationLink {
                        page(RecordingSettingsView())
                    } label: {
                        MenuRow(title: tr("Recording"), systemImage: "location.fill", tint: .green, detail: recordingDetail)
                    }
                    NavigationLink {
                        page(DataSourceView())
                    } label: {
                        MenuRow(title: tr("Data source"), systemImage: "person.2.fill", tint: .teal, detail: model.profile.name)
                    }
                } header: {
                    Text(tr("Recording"))
                }

                Section {
                    NavigationLink {
                        page(DiscoveredAreaView())
                    } label: {
                        MenuRow(title: tr("Discovered area"), systemImage: "square.dashed.inset.filled", tint: .orange,
                                detail: model.staleLayers.isEmpty ? nil : tr("Rebuild needed"),
                                warns: !model.staleLayers.isEmpty)
                    }
                    NavigationLink {
                        page(BuildingDataView())
                    } label: {
                        MenuRow(title: tr("Building data"), systemImage: "building.2.fill", tint: .brown,
                                detail: model.dataRefresh != nil ? tr("Updating…") : nil)
                    }
                    NavigationLink {
                        page(MapDataView())
                    } label: {
                        MenuRow(title: tr("Map data"), systemImage: "externaldrive.fill", tint: .gray)
                    }
                } header: {
                    Text(tr("Data"))
                }

                Section {
                    Picker(selection: $languages.choice) {
                        ForEach(LanguageChoice.allCases) { choice in
                            Text(languages.title(of: choice)).tag(choice)
                        }
                    } label: {
                        MenuRow(title: tr("Language"), systemImage: "globe", tint: .cyan)
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text(tr("Names keep their German original next to the English name. The system's own dialogs (camera, permissions) follow the next time the app starts."))
                }

                Section {
                    Button {
                        // The panel opens over the map, so changes can be watched (and the map used) while tuning.
                        model.opensDebugPanelAfterSettings = true
                        dismiss()
                    } label: {
                        MenuRow(title: tr("Debug settings"), systemImage: "slider.horizontal.3", tint: .purple)
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text(tr("Developer"))
                } footer: {
                    Text(tr("Tune radius, line of sight, fog and recording on the fly, and place test positions – in a panel over the map, which stays usable."))
                }

                Section {
                    Button(tr("Delete all data of “{0}”", model.profile.name), role: .destructive) {
                        confirmDelete = true
                    }
                    .disabled(model.isBusy)
                }
            }
            .navigationTitle(tr("Menu"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { dismiss() }
                }
            }
            .confirmationDialog(
                tr("Delete all positions and discoveries of “{0}”?", model.profile.name),
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button(tr("Delete"), role: .destructive) {
                    Task { await model.deleteAllData() }
                }
            }
        }
        // Another language: the menu is built again, at its first page.
        .id(languages.language)
    }

    /// A page of the menu, with Done to close the menu from there.
    private func page<Content: View>(_ content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(tr("Done")) { dismiss() }
            }
        }
    }

    /// "2D · Fog · All time".
    private var mapViewDetail: String {
        var parts = [mode.rawValue]
        if mode == .twoD { parts.append(model.aggregate == .heatmap ? tr("Heatmap") : tr("Fog")) }
        parts.append(model.currentPeriod?.kind.title ?? tr("All time"))
        return parts.joined(separator: " · ")
    }

    private var recordingDetail: String {
        if !model.profile.recordsLocations { return tr("View only") }
        if !tracker.isAuthorized { return tr("Not allowed") }
        return tracker.isTrackingEnabled ? tr("On") : tr("Off")
    }

    static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return tr("Not asked yet")
        case .restricted: return tr("Restricted")
        case .denied: return tr("Denied")
        case .authorizedAlways: return tr("Always")
        case .authorizedWhenInUse: return tr("While using the app")
        @unknown default: return tr("Unknown")
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
                Toggle(tr("Record positions"), isOn: Binding(
                    get: { tracker.isTrackingEnabled },
                    set: { tracker.isTrackingEnabled = $0 }
                ))
                .disabled(!tracker.isAuthorized || !model.profile.recordsLocations)
                LabeledContent(tr("Permission"), value: SettingsView.describe(tracker.authorizationStatus))
                if tracker.authorizationStatus == .authorizedWhenInUse {
                    Button(tr("Allow background discovery")) {
                        tracker.requestAlwaysAuthorization()
                    }
                }
            } footer: {
                Text(model.profile.recordsLocations
                     ? tr("While recording, every position (about one per second) is added to the track, compactly encoded (≈ 6 bytes per position). The positions that reveal something new also drive the fog of war. The button at the bottom of the map starts and pauses recording too.")
                     : tr("“{0}” shows another user's discoveries and records nothing. Choose your own data under Data source to record.", model.profile.name))
            }
        }
        .navigationTitle(tr("Recording"))
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
                                Text(profile.recordsLocations ? tr("Records your positions") : tr("View only"))
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
                NavigationLink(tr("Add remote data source…")) {
                    AddRemoteSourceView()
                }
            } footer: {
                Text(tr("Location data and discovered area always travel together. Switching the data source shows another user's discoveries – the rest of the app stays the same."))
            }
        }
        .navigationTitle(tr("Data source"))
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
                    LabeledContent(layer.title, value: trn(
                        "{1} in {0} region", "{1} in {0} regions", state.regionCount, Formatters.area(state.discoveredSquareMeters)
                    ))
                    if model.staleLayers.contains(layer) {
                        Label(tr("Some positions are missing in this layer. Rebuild it."), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent(tr("Radius (2D)"), value: tr(
                    "{0} m around each position", Formatters.number(Int(model.circleModel.radius))
                ))
                LabeledContent(tr("Line of sight (3D)"), value: tr(
                    "{0} rays, up to {1} m", Formatters.number(model.viewshedModel.configuration.rayCount),
                    Formatters.number(Int(model.viewshedModel.configuration.maximumDistance))
                ))
            } header: {
                Text(tr("Layers"))
            } footer: {
                if !model.cities.isEmpty {
                    Text(tr(
                        "The fog of war lifts everywhere. {0} also have 3D building and terrain data for the line of sight; elsewhere it reveals the radius circle.",
                        model.cities.map(\.name).formatted(.list(type: .and).locale(Formatters.locale))
                    ))
                }
            }

            Section {
                Button(tr("Fill gaps from your track")) {
                    Task { await model.fillGapsFromTrack() }
                }
                .disabled(model.isBusy)
            } footer: {
                Text(tr("Black spots enclosed by discovered area are filled from the positions in your track that came close to them. This runs once by itself after an update; positions that fill gaps are now kept while recording."))
            }

            Section {
                Button(tr("Rebuild discovered area")) {
                    Task { await model.rebuildDiscoveredArea() }
                }
                .disabled(model.isBusy)
                if let progress = model.progress {
                    ProgressView(value: progress)
                }
            } footer: {
                Text(tr("The discovered area is a cache computed from the stored positions. Rebuilding recomputes both layers from scratch; usually this is not needed – areas are recomputed automatically when building data changes."))
            }
        }
        .navigationTitle(tr("Discovered area"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Building data for the line of sight: bundled, downloaded, missing.
struct BuildingDataView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(tr("Download automatically"), isOn: Binding(
                    get: { model.debug.downloadsBuildings },
                    set: { enabled in
                        var settings = model.debug
                        settings.downloadsBuildings = enabled
                        Task { await model.applyDebugSettings(settings) }
                    }
                ))
                let data = model.buildingData
                LabeledContent(tr("Explored areas"), value: tr(
                    "{0} × {1} km tiles", Formatters.number(data.bundled + data.downloaded + data.missing), Formatters.decimal(1.5, digits: 1)
                ))
                LabeledContent(tr("With building data"), value: tr(
                    "{0} bundled, {1} downloaded", Formatters.number(data.bundled), Formatters.number(data.downloaded)
                ))
                LabeledContent(tr("Default map (no data)"), value: Formatters.number(data.missing))
                if let refresh = model.dataRefresh {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Updating {0} for new building data…", refresh.layer.titleInSentence))
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
                        Text(tr("Download missing building data"))
                        if model.isDownloadingBuildings {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(model.isDownloadingBuildings || data.missing == 0)
            } footer: {
                Text(tr("Building data is bundled for the cities with 3D data and downloaded (OpenStreetMap) only around them. Where none is available (other places, offline), the line-of-sight layer uses the radius circle – the default map. When building data arrives, by download or with a newer bundled dataset, exactly the areas whose view it can change are recomputed from the stored positions."))
            }
        }
        .navigationTitle(tr("Building data"))
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
                LabeledContent(tr("Stored on this iPhone"), value: bytes.map(Formatters.bytes) ?? "…")
                Button(tr("Delete map data"), role: .destructive) {
                    Task {
                        await Task.detached(priority: .userInitiated) { VectorTileStore.shared.clear() }.value
                        await measure()
                    }
                }
                .disabled((bytes ?? 0) == 0)
            } footer: {
                Text(tr("The map is drawn on this iPhone from OpenStreetMap data (OpenFreeMap vector tiles, no labels). Every area you have looked at is kept here, compressed, and works offline; it is refreshed after 90 days and limited to 500 MB. The drawn map is kept too (up to 300 MB), so zooming in and out shows it at once; the next zoom levels are prepared while the map rests."))
            }
        }
        .navigationTitle(tr("Map data"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
    }

    @MainActor
    private func measure() async {
        bytes = await Task.detached(priority: .utility) { VectorTileStore.shared.diskUsage() }.value
    }
}
