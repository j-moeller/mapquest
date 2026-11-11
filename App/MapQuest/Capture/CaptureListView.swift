import CoreLocation
import MapQuestCore
import SwiftUI

/// All sights in one list – captured ones in orange, the others in grey – either
/// nearest first (when the position is known) or through time: by the year they
/// were built, in Berlin's eras. Tapping one opens its entry (locked until
/// captured), which can show it on the map. The third tab lists the achievements.
struct CaptureListView: View {
    enum Order: String, CaseIterable, Identifiable {
        case nearby, timeline, achievements
        var id: String { rawValue }
        var title: String {
            switch self {
            case .nearby: return "Nearby"
            case .timeline: return "Through time"
            case .achievements: return "Achievements"
            }
        }
    }

    @EnvironmentObject private var captures: CaptureModel
    @EnvironmentObject private var tracker: LocationTracker
    @Environment(\.dismiss) private var dismiss
    /// The sights of one era in the timeline.
    struct EraGroup: Identifiable {
        let era: HistoricalEra?
        var sights: [Sight]
        var id: String { era?.id ?? "undated" }
    }

    @AppStorage("sightListOrder") private var order: Order = .nearby

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(captures.capturedCount) of \(captures.catalog.count) sights captured")
                            .font(.headline)
                        Text("\(captures.discoveredCount) discovered · \(captures.collectedStationCount) of \(captures.stations.count) stations collected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if order == .achievements {
                            let progress = captures.achievementProgress
                            Text("\(progress.filter(\.isComplete).count) of \(progress.count) achievements")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(captures.capturedCount), total: Double(max(captures.catalog.count, 1)))
                            .tint(.orange)
                        Picker("Order", selection: $order) {
                            ForEach(Order.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text(footer)
                }
                switch order {
                case .nearby:
                    Section {
                        ForEach(sights, id: \.id) { sight in
                            row(sight, record: captures.log.records[sight.id])
                        }
                    }
                case .achievements:
                    AchievementSections()
                case .timeline:
                    ForEach(timeline) { group in
                        Section {
                            ForEach(group.sights, id: \.id) { sight in
                                row(sight, record: captures.log.records[sight.id], year: captures.histories[sight.id]?.year)
                            }
                        } header: {
                            eraHeader(group.era)
                        }
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

    private var footer: String {
        switch order {
        case .nearby:
            return "A sight is discovered once you have been there – when the circles of the radius view cover it (large parks and squares: when they reach into them) – and its entry opens. Photograph it there to capture it. Stations are collected just by going there."
        case .timeline:
            return "Berlin's history in its sights, by the year they were built. Capture a sight to learn who built it, who ruled at the time, and its story."
        case .achievements:
            return "Complete collections, eras, districts and the works of Berlin's great architects by capturing (photographing) their sights, and the U-Bahn and S-Bahn lines by collecting their stations. Each sight's entry shows what it counts towards."
        }
    }

    /// A sight; in the timeline with the year it was built in front.
    private func row(_ sight: Sight, record: CaptureRecord?, year: Int? = nil) -> some View {
        let discovered = record != nil
        let captured = captures.log.isCaptured(sight.id)
        let isNew = captures.hasUnreadEntry(sight)
        let inTimeline = order == .timeline
        let yearText = year.map { String($0) }
        let state = captured ? "captured" : discovered ? (isNew ? "discovered, new entry, photograph it to capture it" : "discovered, photograph it to capture it") : "not discovered"
        return NavigationLink {
            SightEntryView(sight: sight)
        } label: {
            HStack(spacing: 12) {
                if inTimeline {
                    Text(yearText ?? "–")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(discovered ? Color.orange : Color.secondary)
                        .frame(width: 42, alignment: .leading)
                }
                SightBadge(category: sight.category, captured: captured, discovered: discovered, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(sight.name)
                            .fontWeight(captured ? .semibold : .regular)
                            .foregroundStyle(discovered ? Color.orange : Color.secondary)
                        if isNew {
                            Text("NEW")
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Text(inTimeline ? timelineDetail(for: sight, discovered: discovered) : detail(for: sight, record: record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: captured ? "checkmark.seal.fill" : discovered ? "camera" : "lock.fill")
                    .foregroundStyle(discovered ? Color.orange : Color.secondary)
            }
        }
        .accessibilityLabel(inTimeline && yearText != nil ? "\(yearText!), \(sight.name), \(state)" : "\(sight.name), \(state)")
        .accessibilityHint(discovered ? "Opens its entry" : "Shows how to unlock it")
    }

    /// The sights by the year they were built, grouped by era (East and West
    /// Berlin apart); undated sights last.
    private var timeline: [EraGroup] {
        func year(_ sight: Sight) -> Int { captures.histories[sight.id]?.year ?? .max }
        let sorted = captures.catalog.sights.sorted { a, b in
            year(a) != year(b) ? year(a) < year(b) : a.name < b.name
        }
        var groups: [EraGroup] = []
        var index: [String: Int] = [:]
        for sight in sorted {
            let era = captures.histories[sight.id]?.context?.era
            let id = era?.id ?? "undated"
            if let i = index[id] {
                groups[i].sights.append(sight)
            } else {
                index[id] = groups.count
                groups.append(EraGroup(era: era, sights: [sight]))
            }
        }
        return groups.sorted { a, b in
            (a.era.map { BerlinHistory.order(of: $0) } ?? .max) < (b.era.map { BerlinHistory.order(of: $0) } ?? .max)
        }
    }

    private func eraHeader(_ era: HistoricalEra?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(era?.name ?? "Undated")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if let era {
                    Text(era.years)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let era {
                Text(era.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textCase(nil)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    /// Discovered: style and the ruler at the time; otherwise the category.
    private func timelineDetail(for sight: Sight, discovered: Bool) -> String {
        guard discovered, let history = captures.histories[sight.id] else { return sight.category.title }
        let parts = [history.styles.first, history.context?.ruler?.name].compactMap { $0 }
        return parts.isEmpty ? sight.category.title : parts.joined(separator: " · ")
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

    /// Category, distance, and when it was captured or discovered.
    private func detail(for sight: Sight, record: CaptureRecord?) -> String {
        var parts = [sight.category.title]
        if let location = tracker.lastLocation {
            let meters = distance(to: sight, from: location)
            parts.append(meters < 1_000 ? "\(Int((meters / 10).rounded() * 10)) m away" : String(format: "%.1f km away", meters / 1_000))
        }
        if let photo = captures.log.photos[sight.id] {
            parts.append("captured \(photo.capturedAt.formatted(date: .abbreviated, time: .omitted))")
        } else if record != nil {
            parts.append("photograph it to capture it")
        }
        return parts.joined(separator: " · ")
    }
}

/// A sight's category icon in a round badge: filled orange once captured
/// (photographed), an orange ring once discovered, grey otherwise.
struct SightBadge: View {
    let category: SightCategory
    let captured: Bool
    var discovered: Bool = false
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(captured ? Color.orange : discovered ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.18))
            if discovered && !captured {
                Circle()
                    .strokeBorder(Color.orange, lineWidth: max(1.5, size * 0.06))
            }
            Image(systemName: category.symbol)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(captured ? Color.white : discovered ? Color.orange : Color.secondary)
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
            .overlay(alignment: .topTrailing) {
                // Unread entries.
                if captures.unreadEntryCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: 5, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sights: \(captures.capturedCount) of \(captures.catalog.count) captured")
    }
}

/// The capture component on the main screen: the capture animation over
/// everything, notices of collected stations, the sight list sheet, and
/// forgetting captures of deleted data.
struct CaptureHooks: ViewModifier {
    @ObservedObject var captures: CaptureModel
    @EnvironmentObject private var tracker: LocationTracker

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    if let celebration = captures.celebration {
                        CaptureCelebrationView(
                            celebration: celebration,
                            epoch: celebration.sights.count == 1 ? captures.histories[celebration.sights[0].id]?.epoch : nil,
                            onPhotograph: celebration.sights.count == 1 && captures.canPhotograph(celebration.sights[0], from: tracker.lastLocation)
                                ? { (sight: Sight) in
                                    captures.finishCelebration()
                                    captures.photograph(sight)
                                } : nil,
                            onFinish: { captures.finishCelebration() },
                            onRead: { sight in
                                captures.finishCelebration()
                                captures.openEntry(sight)
                            },
                            onShow: { sight in
                                captures.finishCelebration()
                                captures.show(sight)
                            },
                            onList: {
                                if celebration.kind == .lines {
                                    UserDefaults.standard.set(CaptureListView.Order.achievements.rawValue, forKey: "sightListOrder")
                                }
                                captures.finishCelebration()
                                captures.showsList = true
                            }
                        )
                            .id(celebration.id)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: captures.celebration)
            }
            .overlay(alignment: .top) {
                ZStack {
                    if let toast = captures.stationToast, captures.celebration == nil {
                        StationToastView(toast: toast)
                            .padding(.top, 56)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .id(toast.id)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: captures.stationToast)
                .allowsHitTesting(false)
            }
            .sheet(isPresented: $captures.showsList) {
                CaptureListView()
            }
            .sheet(item: $captures.entry) { sight in
                NavigationStack {
                    SightEntryView(sight: sight)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { captures.entry = nil }
                            }
                        }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .discoveredDataDeleted)) { note in
                if let id = note.object as? String { captures.reset(sourceID: id) }
            }
    }
}
