import Foundation
import MapQuestCore

/// How the map aggregates the positions: the fog of war (the baseline) or a heatmap.
enum MapAggregate: String, CaseIterable, Identifiable {
    case fog
    case heatmap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fog: return tr("Fog of war")
        case .heatmap: return tr("Heatmap")
        }
    }

    var systemImage: String {
        switch self {
        case .fog: return "cloud.fog.fill"
        case .heatmap: return "flame.fill"
        }
    }
}

/// Figures of what the map shows.
struct ViewSummary: Equatable {
    var statistics: TrackStatistics
    /// Area revealed in the period (fog of war only).
    var areaSquareMeters: Double?
}

/// Positions for the heatmap, with a version for renderers.
struct HeatPoints {
    var version = 0
    var points: [WeightedPoint] = []
}

extension PeriodKind {
    var title: String {
        switch self {
        case .day: return tr("Day")
        case .week: return tr("Week")
        case .month: return tr("Month")
        case .year: return tr("Year")
        }
    }

    /// Accessibility label of the button to the period before.
    var previousTitle: String {
        switch self {
        case .day: return tr("Previous day")
        case .week: return tr("Previous week")
        case .month: return tr("Previous month")
        case .year: return tr("Previous year")
        }
    }

    /// Accessibility label of the button to the period after.
    var nextTitle: String {
        switch self {
        case .day: return tr("Next day")
        case .week: return tr("Next week")
        case .month: return tr("Next month")
        case .year: return tr("Next year")
        }
    }
}

extension Period {
    /// "Sun, 8 Nov 2026", "Week 45 · 2–8 Nov", "November 2026", "2026" (in the app's language).
    func title(calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Formatters.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch kind {
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("EEEdMMMyyyy")
            return formatter.string(from: start)
        case .week:
            let week = calendar.component(.weekOfYear, from: start)
            let interval = DateIntervalFormatter()
            interval.locale = Formatters.locale
            interval.calendar = calendar
            interval.timeZone = calendar.timeZone
            interval.dateTemplate = "dMMM"
            return tr("Week {0} · {1}", week, interval.string(from: start, to: end.addingTimeInterval(-1)))
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return formatter.string(from: start)
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("yyyy")
            return formatter.string(from: start)
        }
    }
}

extension AppModel {
    /// The period shown, or `nil` for all time.
    var currentPeriod: Period? {
        periodKind.map { Period($0, containing: periodAnchor, calendar: .current) }
    }

    /// Whether the period shown includes the present (and thus grows while recording).
    var showsPresent: Bool {
        currentPeriod?.contains(Date()) ?? true
    }

    func nextVersion() -> Int {
        versionCounter += 1
        return versionCounter
    }

    /// The fog of war to draw for a layer: all time, or the area of the shown period.
    func displayedState(_ layer: MapLayer) -> LayerState {
        guard periodKind != nil else { return state(layer) }
        return periodStates[layer] ?? LayerState(snapshot: .empty(layer: state(layer).snapshot.layer), identity: "pending", version: 0)
    }

    func showPeriod(_ kind: PeriodKind?) {
        guard kind != periodKind else { return }
        periodKind = kind
        UserDefaults.standard.set(kind?.rawValue, forKey: Self.periodKindKey)
        refreshView()
    }

    func shiftPeriod(by offset: Int) {
        guard let period = currentPeriod else { return }
        periodAnchor = period.shifted(by: offset, calendar: .current).start.addingTimeInterval(1)
        refreshView()
    }

    func showToday() {
        periodAnchor = Date()
        refreshView()
    }

    var canShiftForward: Bool {
        guard let period = currentPeriod else { return false }
        return period.end <= Date()
    }

    /// Called when something was recorded: views of the present are refreshed soon.
    func periodViewTouched() {
        guard showsPresent, periodKind != nil || aggregate == .heatmap else { return }
        scheduleLiveRefresh()
    }

    /// Recomputes what the map shows for the current options (in the background).
    func refreshView() {
        viewTask?.cancel()
        liveViewTask?.cancel()
        liveViewTask = nil
        viewTask = Task { [weak self] in
            await self?.computeView(quiet: false)
        }
        if showsPresent, periodKind != nil || aggregate == .heatmap {
            scheduleLiveRefresh()
        }
    }

    /// While the present is shown, the view follows the growing track.
    private func scheduleLiveRefresh() {
        guard liveViewTask == nil else { return }
        liveViewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.flushTrackOnly()
                await self.computeView(quiet: true)
            }
        }
    }

    private func flushTrackOnly() async {
        try? await trackWriter.flush()
    }

    private func computeView(quiet: Bool) async {
        let period = currentPeriod
        let store = self.store
        let discovery = periodDiscovery
        if !quiet { viewProgress = period == nil ? nil : 0 }
        defer { if !Task.isCancelled { viewProgress = nil } }
        do {
            try? await trackWriter.flush()
            // Heatmap: the positions of the period (or of all time).
            if aggregate == .heatmap && !isShowing3D {
                let points = try await Task.detached(priority: .userInitiated) {
                    try await store.trackPoints(in: period.map { DateInterval(start: $0.start, end: $0.end) })
                        .filter { period?.contains($0.timestamp) ?? true }
                }.value
                guard !Task.isCancelled else { return }
                let weighted = await Task.detached(priority: .userInitiated) { WeightedPoint.timeSpent(points) }.value
                let statistics = await Task.detached(priority: .userInitiated) { TrackStatistics.of(points, calendar: .current) }.value
                guard !Task.isCancelled else { return }
                heatPoints = HeatPoints(version: nextVersion(), points: weighted)
                viewSummary = ViewSummary(statistics: statistics, areaSquareMeters: nil)
                return
            }
            guard let period else {
                viewSummary = nil
                return
            }
            // Fog of war of a period, for the layer(s) on screen.
            let shown: [MapLayer] = isShowing3D ? [.lineOfSight] : [selectedLayer]
            for layer in shown {
                let model: any DiscoveryModel = layer == .radius ? circleModel : viewshedModel
                let area = try await discovery.area(of: period, model: model, sampling: periodSampling(for: layer)) { done, total in
                    Task { @MainActor [weak self] in
                        if !quiet { self?.viewProgress = Double(done) / Double(max(total, 1)) }
                    }
                }
                guard !Task.isCancelled, currentPeriod == period else { return }
                periodStates[layer] = LayerState(
                    snapshot: area.snapshot, identity: "\(model.layer.rawValue)@\(period.key(calendar: .current))",
                    version: nextVersion(), changedTiles: nil,
                    discoveredSquareMeters: area.snapshot.totalAreaSquareMeters, regionCount: 0
                )
                if layer == (isShowing3D ? .lineOfSight : selectedLayer) {
                    viewSummary = ViewSummary(statistics: area.statistics, areaSquareMeters: area.snapshot.totalAreaSquareMeters)
                }
            }
        } catch {
            if !Task.isCancelled { lastOutcome = tr("Could not compute the view: {0}", error.localizedDescription) }
        }
    }

    /// Sampling for period computations: circles tolerate a wider spacing
    /// (scallops of r − √(r² − s²/4): 1.6 m for 50 m circles 25 m apart).
    func periodSampling(for layer: MapLayer) -> CoverageSampler.Configuration {
        var configuration = debug.recordingPolicy.sampling
        if layer == .radius {
            configuration.spacing = max(configuration.spacing, min(25, debug.radius / 2))
        }
        return configuration
    }
}
