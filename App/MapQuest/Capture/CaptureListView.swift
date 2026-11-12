import CoreLocation
import MapQuestCore
import SwiftUI

/// The sights, the achievements and the places of remembrance, in three tabs.
/// Sights: captured ones in orange, the others in grey, nearest first (when the
/// position is known) or through time – by the year they were built, in Berlin's
/// eras. Tapping one opens its entry (locked until discovered), which can show it
/// on the map. Achievements: filtered by how far they are. Remembrance: outside
/// the game, as a short history and walks.
struct CaptureListView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case sights, achievements, remembrance
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sights: return tr("Sights")
            case .achievements: return tr("Achievements")
            case .remembrance: return tr("Remembrance")
            }
        }
    }

    enum Order: String, CaseIterable, Identifiable {
        case nearby, timeline
        var id: String { rawValue }
        var title: String {
            switch self {
            case .nearby: return tr("Nearby")
            case .timeline: return tr("Through time")
            }
        }
    }

    /// The sights of one era in the timeline.
    struct EraGroup: Identifiable {
        let era: HistoricalEra?
        var sights: [Sight]
        var id: String { era?.id ?? "undated" }
    }

    static let tabKey = "sightListTab"

    /// The tab the list opens on next time.
    static func select(_ tab: Tab) {
        UserDefaults.standard.set(tab.rawValue, forKey: tabKey)
    }

    @EnvironmentObject private var captures: CaptureModel
    @EnvironmentObject private var tracker: LocationTracker
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CaptureListView.tabKey) private var tab: Tab = .sights
    @AppStorage("sightListOrder") private var order: Order = .nearby
    @AppStorage("achievementFilter") private var filter: AchievementFilter = .all

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(tr("Show"), selection: $tab) {
                        ForEach(Tab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch tab {
                case .sights:
                    sightSections
                case .achievements:
                    achievementSections
                case .remembrance:
                    RemembranceSections()
                }
            }
            .navigationTitle(tab.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var sightSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("{0} of {1} sights captured", captures.capturedCount, captures.gameSightCount))
                    .font(.headline)
                Text(tr("{0} discovered · {1} of {2} stations collected", captures.discoveredCount,
                        captures.collectedStationCount, captures.stations.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(captures.capturedCount), total: Double(max(captures.gameSightCount, 1)))
                    .tint(.orange)
                Picker(tr("Order"), selection: $order) {
                    ForEach(Order.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        } footer: {
            Text(order == .nearby
                 ? tr("A sight is discovered once you have been there – when the circles of the radius view cover it (large parks and squares: when they reach into them) – and its entry opens. Photograph it there to capture it. Stations are collected just by going there. Places of remembrance are not part of the game: they are under Remembrance.")
                 : tr("Berlin's history in its sights, by the year they were built. Discover a sight to learn who built it, who ruled at the time, and its story. Places of remembrance stand in their year, in grey: they are not part of the game."))
        }
        switch order {
        case .nearby:
            Section {
                ForEach(sights, id: \.id) { sight in
                    row(sight, record: captures.log.records[sight.id])
                }
            }
        case .timeline:
            ForEach(timeline) { group in
                Section {
                    ForEach(group.sights, id: \.id) { sight in
                        if sight.isPlaceOfRemembrance {
                            remembranceRow(sight, year: captures.histories[sight.id]?.year)
                        } else {
                            row(sight, record: captures.log.records[sight.id], year: captures.histories[sight.id]?.year)
                        }
                    }
                } header: {
                    eraHeader(group.era)
                }
            }
        }
    }

    @ViewBuilder
    private var achievementSections: some View {
        let progress = captures.achievementProgress
        let completed = progress.filter(\.isComplete).count
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("{0} of {1} achievements completed", completed, progress.count))
                    .font(.headline)
                ProgressView(value: Double(completed), total: Double(max(progress.count, 1)))
                    .tint(.orange)
                Picker(tr("Show"), selection: $filter) {
                    ForEach(AchievementFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        } footer: {
            Text(tr("Complete collections, eras, districts and the works of Berlin's great architects by capturing (photographing) their sights, and the U-Bahn and S-Bahn lines by collecting their stations. Each sight's entry shows what it counts towards."))
        }
        AchievementSections(filter: filter)
    }

    /// A sight of the game; in the timeline with the year it was built in front.
    private func row(_ sight: Sight, record: CaptureRecord?, year: Int? = nil) -> some View {
        let discovered = record != nil
        let captured = captures.log.isCaptured(sight.id)
        let isNew = captures.hasUnreadEntry(sight)
        let inTimeline = order == .timeline
        let yearText = year.map { String($0) }
        let state = captured ? tr("captured")
            : discovered ? (isNew ? tr("discovered, new entry, photograph it to capture it") : tr("discovered, photograph it to capture it"))
            : tr("not discovered")
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
                            Text(tr("NEW"))
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
        .accessibilityHint(discovered ? tr("Opens its entry") : tr("Shows how to unlock it"))
    }

    /// A place of remembrance in the timeline: in its year, in stone grey, without
    /// any game state – what it remembers, and that it is not part of the game.
    private func remembranceRow(_ sight: Sight, year: Int?) -> some View {
        let yearText = year.map { String($0) }
        let remembers = captures.remembrance.remembers(sight.id)
        return NavigationLink {
            SightEntryView(sight: sight)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(yearText ?? "–")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                SightBadge(category: sight.category, captured: false, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sight.name)
                        .foregroundStyle(.primary)
                    Text(tr("Place of remembrance · not part of the game"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let remembers {
                        Text(remembers)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .accessibilityLabel(yearText.map { tr("{0}, {1}, place of remembrance, not part of the game", $0, sight.name) }
                            ?? tr("{0}, place of remembrance, not part of the game", sight.name))
        .accessibilityHint(tr("Opens its entry"))
    }

    /// The sights by the year they were built, grouped by era (East and West
    /// Berlin apart); undated sights last. Places of remembrance stand in their
    /// year too, outside the game.
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
                Text(era?.name ?? tr("Undated"))
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

    /// The sights of the game, nearest first when the position is known, else by name.
    private var sights: [Sight] {
        let all = captures.catalog.sights.filter { !$0.isPlaceOfRemembrance }
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
            parts.append(tr("{0} away", Formatters.away(distance(to: sight, from: location))))
        }
        if let photo = captures.log.photos[sight.id] {
            parts.append(tr("captured {0}", Formatters.date(photo.capturedAt)))
        } else if record != nil {
            parts.append(tr("photograph it to capture it"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A sight's category icon in a round badge: filled orange once captured
/// (photographed), an orange ring once discovered, grey otherwise; places of
/// remembrance always in stone grey.
struct SightBadge: View {
    let category: SightCategory
    let captured: Bool
    var discovered: Bool = false
    var size: CGFloat = 34

    var body: some View {
        if category.isRemembrance {
            // Places of remembrance: one quiet look, no game states.
            ZStack {
                Circle()
                    .fill(Color.remembrance)
                Image(systemName: category.symbol)
                    .font(.system(size: size * 0.38, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            gameBadge
        }
    }

    private var gameBadge: some View {
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

/// The capture component on the main screen: the capture animation over
/// everything, the quiet note on places of remembrance, notices of collected
/// stations, the sight list sheet, and forgetting captures of deleted data.
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
                                CaptureListView.select(celebration.kind == .lines ? .achievements : .sights)
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
            .overlay {
                ZStack {
                    if let notice = captures.remembranceNotice {
                        RemembranceNoticeView(
                            notice: notice,
                            intro: { captures.infos[$0.id]?.paragraphs.first },
                            onRead: { sight in
                                captures.finishRemembranceNotice()
                                captures.openEntry(sight)
                            },
                            onClose: { captures.finishRemembranceNotice() }
                        )
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: captures.remembranceNotice)
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
                                Button(tr("Done")) { captures.entry = nil }
                            }
                        }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .discoveredDataDeleted)) { note in
                if let id = note.object as? String { captures.reset(sourceID: id) }
            }
    }
}
