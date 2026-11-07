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
                } header: {
                    Text("Data source")
                } footer: {
                    Text("Location data and discovered area always travel together. Switching the data source shows another user's discoveries – the rest of the app stays the same.")
                }

                Section {
                    LabeledContent("Discovery radius", value: "\(Int(model.circleModel.radius)) m")
                    LabeledContent("Stored positions", value: "\(model.statistics.sampleCount)")
                    LabeledContent("Discovered area", value: Formatters.area(model.statistics.discoveredSquareMeters))
                    LabeledContent("Regions", value: "\(model.statistics.regionCount)")
                    Button("Rebuild discovered area") {
                        Task { await model.rebuildDiscoveredArea() }
                    }
                    .disabled(model.isBusy)
                } header: {
                    Text("Discovery")
                } footer: {
                    Text("The discovered area is a cache computed from the stored positions. Rebuilding recomputes it from scratch.")
                }

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
                    Text("Only positions that reveal something new are stored – nothing is recorded while you move through known territory.")
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
