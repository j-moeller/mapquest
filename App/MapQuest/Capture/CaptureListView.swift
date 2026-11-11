import CoreLocation
import MapQuestCore
import SwiftUI

/// Available and captured sights; tapping one shows it on the map.
struct CaptureListView: View {
    @EnvironmentObject private var captures: CaptureModel
    @EnvironmentObject private var tracker: LocationTracker
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.available

    enum Tab: String, CaseIterable, Identifiable {
        case available = "Available"
        case captured = "Captured"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(captures.capturedCount) of \(captures.catalog.count) sights captured")
                            .font(.headline)
                        ProgressView(value: Double(captures.capturedCount), total: Double(max(captures.catalog.count, 1)))
                            .tint(.captureGold)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("A sight is captured once you have been there: when the circles of the radius view cover it (large parks and squares: when they reach into them). Seeing it from a distance does not count.")
                }
                Section {
                    switch tab {
                    case .available:
                        if available.isEmpty {
                            Text("All sights captured!")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(available) { sight in
                            row(sight, detail: detail(for: sight), captured: false)
                        }
                    case .captured:
                        if captures.captured.isEmpty {
                            Text("No sights captured yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(captures.captured) { item in
                            row(item.sight, detail: "\(item.sight.category.title) · \(item.record.capturedAt.formatted(date: .abbreviated, time: .omitted))", captured: true)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Sights", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .navigationTitle("Sights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ sight: Sight, detail: String, captured: Bool) -> some View {
        Button {
            captures.show(sight)
        } label: {
            HStack(spacing: 12) {
                SightBadge(category: sight.category, captured: captured, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sight.name)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "map")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("Shows the sight on the map")
    }

    /// Available sights, nearest first when the position is known.
    private var available: [Sight] {
        let sights = captures.available
        guard let location = tracker.lastLocation else { return sights.sorted { $0.name < $1.name } }
        return sights.sorted { distance(to: $0, from: location) < distance(to: $1, from: location) }
    }

    private func distance(to sight: Sight, from location: CLLocation) -> CLLocationDistance {
        location.distance(from: CLLocation(latitude: sight.latitude, longitude: sight.longitude))
    }

    private func detail(for sight: Sight) -> String {
        guard let location = tracker.lastLocation else { return sight.category.title }
        let meters = distance(to: sight, from: location)
        let text = meters < 1_000 ? "\(Int((meters / 10).rounded() * 10)) m" : String(format: "%.1f km", meters / 1_000)
        return "\(sight.category.title) · \(text) away"
    }
}

/// A sight's category icon in a round badge: gold once captured.
struct SightBadge: View {
    let category: SightCategory
    let captured: Bool
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(captured
                      ? AnyShapeStyle(LinearGradient(colors: [.captureGold, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                      : AnyShapeStyle(Color.secondary.opacity(0.18)))
            Image(systemName: category.symbol)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(captured ? Color.white : Color.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The trophy button with the number of captures.
struct CaptureButton: View {
    @EnvironmentObject private var captures: CaptureModel

    var body: some View {
        Button {
            captures.showsList = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "trophy.fill")
                Text("\(captures.capturedCount)")
                    .font(.subheadline.monospacedDigit().bold())
            }
            .foregroundStyle(Color.captureGold)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sights: \(captures.capturedCount) of \(captures.catalog.count) captured")
    }
}

/// The capture component on the main screen: the capture animation over
/// everything, the sight list sheet, and forgetting captures of deleted data.
struct CaptureHooks: ViewModifier {
    @ObservedObject var captures: CaptureModel

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    if let celebration = captures.celebration {
                        CaptureCelebrationView(celebration: celebration) { captures.finishCelebration() }
                            .id(celebration.id)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: captures.celebration)
            }
            .sheet(isPresented: $captures.showsList) {
                CaptureListView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .discoveredDataDeleted)) { note in
                if let id = note.object as? String { captures.reset(sourceID: id) }
            }
    }
}
