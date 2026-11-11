import CoreLocation
import MapQuestCore
import SwiftUI

/// All sights in one list – captured ones in orange, the others in grey – nearest
/// first when the position is known; tapping one shows it on the map.
struct CaptureListView: View {
    @EnvironmentObject private var captures: CaptureModel
    @EnvironmentObject private var tracker: LocationTracker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(captures.capturedCount) of \(captures.catalog.count) sights captured")
                            .font(.headline)
                        ProgressView(value: Double(captures.capturedCount), total: Double(max(captures.catalog.count, 1)))
                            .tint(.orange)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("A sight is captured once you have been there: when the circles of the radius view cover it (large parks and squares: when they reach into them). Seeing it from a distance does not count.")
                }
                Section {
                    ForEach(sights, id: \.id) { sight in
                        row(sight, record: captures.log.records[sight.id])
                    }
                }
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

    private func row(_ sight: Sight, record: CaptureRecord?) -> some View {
        let captured = record != nil
        return Button {
            captures.show(sight)
        } label: {
            HStack(spacing: 12) {
                SightBadge(category: sight.category, captured: captured, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sight.name)
                        .fontWeight(captured ? .semibold : .regular)
                        .foregroundStyle(captured ? Color.orange : Color.secondary)
                    Text(detail(for: sight, record: record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: captured ? "checkmark.seal.fill" : "map")
                    .foregroundStyle(captured ? Color.orange : Color.secondary)
            }
        }
        .accessibilityLabel("\(sight.name), \(captured ? "captured" : "not captured")")
        .accessibilityHint("Shows the sight on the map")
    }

    /// Every sight, nearest first when the position is known, else by name.
    private var sights: [Sight] {
        let all = captures.catalog.sights
        guard let location = tracker.lastLocation else { return all.sorted { $0.name < $1.name } }
        return all.sorted { distance(to: $0, from: location) < distance(to: $1, from: location) }
    }

    private func distance(to sight: Sight, from location: CLLocation) -> CLLocationDistance {
        location.distance(from: CLLocation(latitude: sight.latitude, longitude: sight.longitude))
    }

    /// Category, distance, and the capture date of captured sights.
    private func detail(for sight: Sight, record: CaptureRecord?) -> String {
        var parts = [sight.category.title]
        if let location = tracker.lastLocation {
            let meters = distance(to: sight, from: location)
            parts.append(meters < 1_000 ? "\(Int((meters / 10).rounded() * 10)) m away" : String(format: "%.1f km away", meters / 1_000))
        }
        if let record {
            parts.append("captured \(record.capturedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }
}

/// A sight's category icon in a round badge: orange once captured, grey otherwise.
struct SightBadge: View {
    let category: SightCategory
    let captured: Bool
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(captured ? Color.orange : Color.secondary.opacity(0.18))
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
