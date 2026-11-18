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
            AchievementSymbol(name: symbol, size: size * 0.4, color: complete ? Color.white : Color.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// An achievement's symbol. The U-Bahn and S-Bahn signs keep their colours, as
/// on the real signs: a white "U" on a blue square, a white "S" on a green circle.
struct AchievementSymbol: View {
    let name: String
    let size: CGFloat
    /// The colour of every other symbol.
    var color: Color = .secondary

    /// The system whose sign the symbol is.
    static func sign(_ name: String) -> TransitSystem? {
        switch name {
        case "u.square.fill": return .ubahn
        case "s.circle.fill": return .sbahn
        default: return nil
        }
    }

    var body: some View {
        if let system = Self.sign(name) {
            Image(systemName: name)
                .font(.system(size: size * 1.35, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color(uiColor: system.signColor))
        } else {
            Image(systemName: AchievementMedal.symbol(name))
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

/// Which achievements the list shows: all, the completed ones, the ones under
/// way, or the ones not started yet.
enum AchievementFilter: String, CaseIterable, Identifiable {
    case all, completed, started, notStarted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return tr("All")
        case .completed: return tr("Completed")
        case .started: return tr("Started")
        case .notStarted: return tr("Not started")
        }
    }

    func includes(_ progress: AchievementProgress) -> Bool {
        switch self {
        case .all: return true
        case .completed: return progress.isComplete
        case .started: return !progress.isComplete && progress.count > 0
        case .notStarted: return progress.count == 0 && !progress.isComplete
        }
    }

    /// When nothing matches.
    var emptyText: String {
        switch self {
        case .all: return tr("No achievements here.")
        case .completed: return tr("No achievement completed yet. Capture sights by photographing them, and collect stations by going there.")
        case .started: return tr("No achievement under way. Capture a sight or collect a station to start one.")
        case .notStarted: return tr("You have started every achievement.")
        }
    }
}

/// The achievements by group, the ones nearly done first.
struct AchievementSections: View {
    @EnvironmentObject private var captures: CaptureModel
    var filter: AchievementFilter = .all
    /// The city whose achievements are shown (all with `nil`).
    var city: String?

    var body: some View {
        let all = captures.achievementProgress(in: city)
        let shown = all.filter { self.filter.includes($0) }
        // Started, not milestones, fewest sights to go first.
        let almost = all
            .filter { !$0.isComplete && $0.count > 0 && !$0.achievement.rule.isMilestone }
            .sorted { ($0.remaining, -$0.fraction, $0.achievement.title) < ($1.remaining, -$1.fraction, $1.achievement.title) }
            .prefix(3)
        if !almost.isEmpty && (filter == .all || filter == .started) {
            Section {
                ForEach(Array(almost)) { progress in
                    AchievementRow(progress: progress)
                }
            } header: {
                Text(tr("Almost there"))
            }
        }
        if shown.isEmpty {
            Section {
                Text(filter.emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(AchievementGroup.allCases, id: \.self) { group in
            let items = shown.filter { $0.achievement.group == group }
            if !items.isEmpty {
                let ofGroup = all.filter { $0.achievement.group == group }
                Section {
                    ForEach(items) { progress in
                        AchievementRow(progress: progress)
                    }
                } header: {
                    Text("\(group.title) · \(ofGroup.filter(\.isComplete).count)/\(ofGroup.count)")
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
        .accessibilityLabel(progress.achievement.title + ", "
                            + (progress.isComplete ? tr("complete") : tr("{0} of {1}", progress.count, progress.target)))
    }
}

/// An achievement: what it asks for, the sight to go for next, and its sights.
struct AchievementDetailView: View {
    let achievementID: String
    @EnvironmentObject private var captures: CaptureModel
    @EnvironmentObject private var tracker: LocationTracker

    var body: some View {
        if let entry = captures.achievements[achievementID] {
            let progress = captures.achievements.progress(of: entry, captured: captures.log.captureDates)
            let aboutStations = entry.achievement.rule.isAboutStations
            List {
                Section {
                    header(progress)
                }
                if aboutStations {
                    stationSections(entry, progress: progress)
                } else if !progress.isComplete, let next = captures.nextSight(in: progress, from: tracker.lastLocation) {
                    Section {
                        sightRow(next, distance: true)
                        Button {
                            captures.show(next)
                        } label: {
                            Label(tr("Show on map"), systemImage: "map")
                        }
                        .tint(.orange)
                    } header: {
                        Text(tracker.lastLocation == nil ? tr("Next up") : tr("Next up: the nearest"))
                    }
                }
                if !entry.achievement.rule.isMilestone && !aboutStations {
                    Section {
                        ForEach(entry.members, id: \.self) { id in
                            if let sight = captures.catalog[id] {
                                sightRow(sight, distance: false)
                            }
                        }
                    } header: {
                        Text(tr("Sights") + " · \(progress.count)/\(progress.target)")
                    } footer: {
                        Text(tr("A sight counts once it is captured: discovered by going there, then photographed."))
                    }
                }
            }
            .navigationTitle(entry.achievement.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text(tr("This achievement does not exist (any more)."))
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
                Label(tr("Completed {0}", Formatters.date(completedAt, .long)), systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Text(tr("{0} of {1} – {2} to go", progress.count, progress.target, progress.remaining))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// The nearest station still to collect, and – for a line – its stations in order.
    @ViewBuilder
    private func stationSections(_ entry: AchievementBook.Entry, progress: AchievementProgress) -> some View {
        if !progress.isComplete, let next = captures.nextStation(in: progress, from: tracker.lastLocation) {
            Section {
                stationRow(next, distance: true)
                Button {
                    captures.show(next)
                } label: {
                    Label(tr("Show on map"), systemImage: "map")
                }
                .tint(.orange)
            } header: {
                Text(tracker.lastLocation == nil ? tr("Next up") : tr("Next up: the nearest"))
            }
        }
        if entry.achievement.rule.line != nil || entry.members.count <= 200 {
            Section {
                ForEach(entry.members, id: \.self) { id in
                    if let station = captures.stations[id] {
                        stationRow(station, distance: false)
                    }
                }
            } header: {
                Text(tr("Stations") + " · \(progress.count)/\(progress.target)")
            } footer: {
                Text(tr("A station is collected by going there – walking past it, or riding through it above ground. No photo needed."))
            }
        }
    }

    private func stationRow(_ station: Station, distance: Bool) -> some View {
        let collected = captures.log.stations[station.id] != nil
        return HStack(spacing: 12) {
            StationBadge(system: station.system, collected: collected, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .fontWeight(collected ? .semibold : .regular)
                    .foregroundStyle(collected ? Color.primary : Color.secondary)
                let lines = station.lines.joined(separator: " · ")
                if distance, let location = tracker.lastLocation {
                    let meters = location.distance(from: CLLocation(latitude: station.latitude, longitude: station.longitude))
                    Text(tr("{0} away", Formatters.away(meters)) + " · " + lines)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(station.district.map { "\(lines) · \($0)" } ?? lines)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: collected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(collected ? Color.orange : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { captures.show(station) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(station.system.title) \(station.name), " + (collected ? tr("collected") : tr("not collected")))
        .accessibilityHint(tr("Shows it on the map"))
    }

    /// A sight with the year it was built; tapping it opens its entry.
    private func sightRow(_ sight: Sight, distance: Bool) -> some View {
        let discovered = captures.log.records[sight.id] != nil
        let captured = captures.log.isCaptured(sight.id)
        let year = captures.histories[sight.id]?.year
        return NavigationLink {
            SightEntryView(sight: sight)
        } label: {
            HStack(spacing: 12) {
                Text(year.map { String($0) } ?? "–")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(discovered ? Color.orange : Color.secondary)
                    .frame(width: 42, alignment: .leading)
                SightBadge(category: sight.category, captured: captured, discovered: discovered, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sight.name)
                        .fontWeight(captured ? .semibold : .regular)
                        .foregroundStyle(discovered ? Color.orange : Color.primary)
                    if distance, let location = tracker.lastLocation {
                        let meters = location.distance(from: CLLocation(latitude: sight.latitude, longitude: sight.longitude))
                        Text(tr("{0} away", Formatters.away(meters)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let district = sight.district {
                        Text(district)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: captured ? "checkmark.circle.fill" : discovered ? "camera" : "circle")
                    .foregroundStyle(discovered ? Color.orange : Color.secondary)
            }
        }
        .accessibilityLabel(sight.name + ", "
                            + (captured ? tr("captured") : discovered ? tr("discovered, photograph it to capture it") : tr("not discovered")))
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
                Label(tr("Counts towards"), systemImage: "rosette")
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
