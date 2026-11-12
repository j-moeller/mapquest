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
                            Text("\(state.regionCount) \(state.regionCount == 1 ? "region" : "regions")")
                            Spacer()
                            if let share = model.playAreaFraction(layer) {
                                Text("\(Formatters.percent(share.fraction)) of \(share.city)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if model.staleLayers.contains(layer) {
                            Label("Some positions are missing in this layer. Rebuild it under Discovered area.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                LabeledContent("Track", value: Formatters.track(model.trackSummary))
                LabeledContent("Map-changing positions", value: model.sampleCount.formatted())
                if !model.cities.isEmpty {
                    NavigationLink("Cities and districts") {
                        DistrictsView()
                    }
                }
            } header: {
                Text("Discovered")
            } footer: {
                Text("Everything discovered with “\(model.profile.name)”, all time. Radius: everything around your positions. Line of sight: what you could see between the buildings.")
            }

            if model.periodKind != nil || model.aggregate == .heatmap {
                Section {
                    let summary = model.viewSummary
                    if let progress = model.viewProgress {
                        ProgressView(value: progress) {
                            Text("Computing…").font(.caption)
                        }
                    }
                    if let area = summary?.areaSquareMeters {
                        LabeledContent("Area seen", value: Formatters.area(area))
                    }
                    LabeledContent("Distance travelled", value: Formatters.distance(summary?.statistics.distanceMeters ?? 0))
                    LabeledContent("Time recorded", value: Formatters.duration(summary?.statistics.recordedSeconds ?? 0))
                    if model.periodKind != .day {
                        LabeledContent("Active days", value: "\(summary?.statistics.activeDays ?? 0)")
                    }
                } header: {
                    Text(shownTitle)
                } footer: {
                    Text("What the map shows now. Change it under Map view.")
                }
            }

            Section {
                LabeledContent("Sights captured", value: "\(captures.capturedCount) of \(captures.gameSightCount)")
                LabeledContent("Sights discovered", value: "\(captures.discoveredCount) of \(captures.gameSightCount)")
                LabeledContent("Stations collected", value: "\(captures.collectedStationCount) of \(captures.stations.count)")
                let progress = captures.achievementProgress
                LabeledContent("Achievements", value: "\(progress.filter(\.isComplete).count) of \(progress.count)")
            } header: {
                Text("Sights")
            } footer: {
                Text("A sight is discovered when you go there and captured when you take its photo there. Stations are collected by going there. Places of remembrance are not counted.")
            }

            if hasStatus {
                Section {
                    if let refresh = model.dataRefresh {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Updating \(refresh.layer.title.lowercased()) for new building data", systemImage: "building.2")
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
                            Text("Working…").font(.subheadline)
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
                    Text("Status")
                }
            }
        }
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "Week 45 · 2–8 Nov", "Heatmap · All time".
    private var shownTitle: String {
        var parts: [String] = []
        if model.aggregate == .heatmap && !model.isShowing3D { parts.append(MapAggregate.heatmap.title) }
        parts.append(model.currentPeriod?.title() ?? "All time")
        return parts.joined(separator: " · ")
    }

    private var hasStatus: Bool {
        model.dataRefresh != nil || model.progress != nil || !model.lastOutcome.isEmpty
            || (model.evaluationSummary != nil && model.debug.showsEvaluation)
    }
}
