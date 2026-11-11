import CoreLocation
import MapQuestCore
import SwiftUI
import UIKit

/// An achievement's medal: gold once complete, otherwise grey with a ring
/// showing how far it is.
struct AchievementMedal: View {
    let symbol: String
    let fraction: Double
    let complete: Bool
    var size: CGFloat = 44

    /// The SF Symbol, or a star if this system does not know it.
    static func symbol(_ name: String) -> String {
        UIImage(systemName: name) == nil ? "star.fill" : name
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(complete
                      ? AnyShapeStyle(LinearGradient(colors: [Color.captureGold, Color.orange], startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(Color.secondary.opacity(0.15)))
            if !complete && fraction > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: max(2, size * 0.07), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(size * 0.05)
            }
            Image(systemName: Self.symbol(symbol))
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(complete ? Color.white : Color.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The achievements in the sight list: those almost complete first, then by group.
struct AchievementSections: View {
    @EnvironmentObject private var captures: CaptureModel

    var body: some View {
        let all = captures.achievementProgress
        // Started, not milestones, fewest sights to go first.
        let almost = all
            .filter { !$0.isComplete && $0.count > 0 && !$0.achievement.rule.isMilestone }
            .sorted { ($0.remaining, -$0.fraction, $0.achievement.title) < ($1.remaining, -$1.fraction, $1.achievement.title) }
            .prefix(3)
        if !almost.isEmpty {
            Section {
                ForEach(Array(almost)) { progress in
                    AchievementRow(progress: progress)
                }
            } header: {
                Text("Almost there")
            }
        }
        ForEach(AchievementGroup.allCases, id: \.self) { group in
            let items = all.filter { $0.achievement.group == group }
            if !items.isEmpty {
                Section {
                    ForEach(items) { progress in
                        AchievementRow(progress: progress)
                    }
                } header: {
                    Text("\(group.title) · \(items.filter(\.isComplete).count)/\(items.count)")
                }
            }
        }
    }
}

/// An achievement in a list: medal, title, description and progress.
struct AchievementRow: View {
    let progress: AchievementProgress
    var compact = false

    var body: some View {
        NavigationLink {
            AchievementDetailView(achievementID: progress.id)
        } label: {
            HStack(spacing: 12) {
                AchievementMedal(symbol: progress.achievement.symbol, fraction: progress.fraction, complete: progress.isComplete,
                                 size: compact ? 34 : 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress.achievement.title)
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .foregroundStyle(progress.isComplete ? Color.orange : Color.primary)
                    if !compact {
                        Text(progress.achievement.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        ProgressView(value: progress.fraction)
                            .tint(progress.isComplete ? Color.captureGold : Color.orange)
                        Text(verbatim: "\(progress.count)/\(progress.target)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, compact ? 0 : 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.achievement.title), \(progress.isComplete ? "complete" : "\(progress.count) of \(progress.target)")")
    }
}

/// An achievement: what it asks for, the sight to go for next, and its sights.
struct AchievementDetailView: View {
    let achievementID: String
    @EnvironmentObject private var captures: CaptureModel
    @EnvironmentObject private var tracker: LocationTracker

    var body: some View {
        if let entry = captures.achievements[achievementID] {
            let progress = captures.achievements.progress(of: entry, records: captures.log.records)
            List {
                Section {
                    header(progress)
                }
                if !progress.isComplete, let next = captures.nextSight(in: progress, from: tracker.lastLocation) {
                    Section {
                        sightRow(next, distance: true)
                        Button {
                            captures.show(next)
                        } label: {
                            Label("Show on map", systemImage: "map")
                        }
                        .tint(.orange)
                    } header: {
                        Text(tracker.lastLocation == nil ? "Next up" : "Next up: the nearest")
                    }
                }
                if !entry.achievement.rule.isMilestone {
                    Section {
                        ForEach(entry.members, id: \.self) { id in
                            if let sight = captures.catalog[id] {
                                sightRow(sight, distance: false)
                            }
                        }
                    } header: {
                        Text(verbatim: "Sights · \(progress.count)/\(progress.target)")
                    }
                }
            }
            .navigationTitle(entry.achievement.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("This achievement does not exist (any more).")
                .foregroundStyle(.secondary)
        }
    }

    private func header(_ progress: AchievementProgress) -> some View {
        VStack(spacing: 10) {
            AchievementMedal(symbol: progress.achievement.symbol, fraction: progress.fraction, complete: progress.isComplete, size: 86)
            Text(progress.achievement.group.title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(progress.achievement.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(progress.achievement.description)
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: progress.fraction)
                .tint(progress.isComplete ? Color.captureGold : Color.orange)
            if let completedAt = progress.completedAt {
                Label("Completed \(completedAt.formatted(date: .long, time: .omitted))", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Text(verbatim: "\(progress.count) of \(progress.target) – \(progress.remaining) to go")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// A sight with the year it was built; tapping it opens its entry.
    private func sightRow(_ sight: Sight, distance: Bool) -> some View {
        let captured = captures.log.records[sight.id] != nil
        let year = captures.histories[sight.id]?.year
        return NavigationLink {
            SightEntryView(sight: sight)
        } label: {
            HStack(spacing: 12) {
                Text(year.map { String($0) } ?? "–")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(captured ? Color.orange : Color.secondary)
                    .frame(width: 42, alignment: .leading)
                SightBadge(category: sight.category, captured: captured, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sight.name)
                        .fontWeight(captured ? .semibold : .regular)
                        .foregroundStyle(captured ? Color.orange : Color.primary)
                    if distance, let location = tracker.lastLocation {
                        let meters = location.distance(from: CLLocation(latitude: sight.latitude, longitude: sight.longitude))
                        Text(meters < 1_000 ? "\(Int((meters / 10).rounded() * 10)) m away" : String(format: "%.1f km away", meters / 1_000))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let district = sight.district {
                        Text(district)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: captured ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(captured ? Color.orange : Color.secondary)
            }
        }
        .accessibilityLabel("\(sight.name), \(captured ? "captured" : "not captured")")
    }
}

/// The achievements a sight counts towards, in its entry.
struct SightAchievements: View {
    let sight: Sight
    @EnvironmentObject private var captures: CaptureModel

    var body: some View {
        let items = captures.achievementProgress(containing: sight)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Counts towards", systemImage: "rosette")
                    .font(.headline)
                    .foregroundStyle(Color.orange)
                ForEach(items) { progress in
                    AchievementRow(progress: progress, compact: true)
                        .buttonStyle(.plain)
                    if progress.id != items.last?.id {
                        Divider()
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
