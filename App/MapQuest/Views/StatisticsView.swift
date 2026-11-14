import MapQuestCore
import SwiftUI

/// The figures: what you have discovered (all time), what the map shows (a time
/// span or the heatmap), the sights, stations and achievements, and what the
/// app is working on.
struct StatisticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var captures: CaptureModel

    var body: some View {
        Form {
            Section {
                ForEach(MapLayer.allCases) { layer in
                    let state = model.state(layer)
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(layer.title, value: Formatters.area(state.discoveredSquareMeters))
                        HStack {
                            Text(trn("{0} region", "{0} regions", state.regionCount))
                            Spacer()
                            if let share = model.playAreaFraction(layer) {
                                Text(tr("{0} of {1}", Formatters.percent(share.fraction), share.city))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if model.staleLayers.contains(layer) {
                            Label(tr("Some positions are missing in this layer. Rebuild it under Discovered area."), systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                // Every second while this page is open (the model publishes the count only every 10 s).
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent(tr("Track"), value: Formatters.track(model.liveTrackSummary))
                }
                LabeledContent(tr("Map-changing positions"), value: Formatters.number(model.sampleCount))
                if !model.cities.isEmpty {
                    NavigationLink(tr("Cities and districts")) {
                        DistrictsView()
                    }
                }
            } header: {
                Text(tr("Discovered"))
            } footer: {
                Text(tr("Everything discovered with “{0}”, all time. Radius: everything around your positions. Line of sight: what you could see between the buildings.", model.profile.name))
            }

            if model.periodKind != nil || model.aggregate == .heatmap {
                Section {
                    let summary = model.viewSummary
                    if let progress = model.viewProgress {
                        ProgressView(value: progress) {
                            Text(tr("Computing…")).font(.caption)
                        }
                    }
                    if let area = summary?.areaSquareMeters {
                        LabeledContent(tr("Area seen"), value: Formatters.area(area))
                    }
                    LabeledContent(tr("Distance travelled"), value: Formatters.distance(summary?.statistics.distanceMeters ?? 0))
                    LabeledContent(tr("Time recorded"), value: Formatters.duration(summary?.statistics.recordedSeconds ?? 0))
                    if model.periodKind != .day {
                        LabeledContent(tr("Active days"), value: Formatters.number(summary?.statistics.activeDays ?? 0))
                    }
                } header: {
                    Text(shownTitle)
                } footer: {
                    Text(tr("What the map shows now. Change it under Map view."))
                }
            }

            Section {
                LabeledContent(tr("Sights captured"), value: tr("{0} of {1}", captures.capturedCount, captures.gameSightCount))
                LabeledContent(tr("Sights discovered"), value: tr("{0} of {1}", captures.discoveredCount, captures.gameSightCount))
                LabeledContent(tr("Stations collected"), value: tr("{0} of {1}", captures.collectedStationCount, captures.stations.count))
                let progress = captures.achievementProgress
                LabeledContent(tr("Achievements"), value: tr("{0} of {1}", progress.filter(\.isComplete).count, progress.count))
            } header: {
                Text(tr("Sights"))
            } footer: {
                Text(tr("A sight is discovered when you go there and captured when you take its photo there. Stations are collected by going there. Places of remembrance are not counted."))
            }

            if hasStatus {
                Section {
                    if let refresh = model.dataRefresh {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(tr("Updating {0} for new building data…", refresh.layer.titleInSentence), systemImage: "building.2")
                                .font(.subheadline)
                            if let fraction = refresh.fraction {
                                ProgressView(value: fraction)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                    if let progress = model.progress {
                        ProgressView(value: progress) {
                            Text(tr("Working…")).font(.subheadline)
                        }
                    }
                    if !model.lastOutcome.isEmpty {
                        Text(model.lastOutcome)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let summary = model.evaluationSummary, model.debug.showsEvaluation {
                        Text(summary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(tr("Status"))
                }
            }
        }
        .navigationTitle(tr("Statistics"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "Week 45 · 2–8 Nov", "Heatmap · All time".
    private var shownTitle: String {
        var parts: [String] = []
        if model.aggregate == .heatmap && !model.isShowing3D { parts.append(MapAggregate.heatmap.title) }
        parts.append(model.currentPeriod?.title() ?? tr("All time"))
        return parts.joined(separator: " · ")
    }

    private var hasStatus: Bool {
        model.dataRefresh != nil || model.progress != nil || !model.lastOutcome.isEmpty
            || (model.evaluationSummary != nil && model.debug.showsEvaluation)
    }
}
