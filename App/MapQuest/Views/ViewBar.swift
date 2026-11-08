import MapQuestCore
import SwiftUI

/// Viewing options above the map: fog of war or heatmap, and the time span
/// (all time, or a day, week, month or year with navigation).
struct ViewBar: View {
    @EnvironmentObject private var model: AppModel
    /// The 3D scene only shows the fog of war.
    var showsAggregate = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if showsAggregate {
                    Menu {
                        Picker("Show", selection: $model.aggregate) {
                            ForEach(MapAggregate.allCases) { aggregate in
                                Label(aggregate.title, systemImage: aggregate.systemImage).tag(aggregate)
                            }
                        }
                    } label: {
                        Image(systemName: model.aggregate.systemImage)
                            .frame(width: 36, height: 30)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("Show: \(model.aggregate.title)")
                }
                Menu {
                    Picker("Time", selection: Binding(get: { model.periodKind }, set: { model.showPeriod($0) })) {
                        Text("All time").tag(PeriodKind?.none)
                        ForEach(PeriodKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(PeriodKind?.some(kind))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                        Text(model.periodKind?.title ?? "All time")
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Time span: \(model.periodKind?.title ?? "All time")")
            }
            if let period = model.currentPeriod {
                HStack(spacing: 4) {
                    Button {
                        model.shiftPeriod(by: -1)
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 30, height: 30)
                    }
                    .accessibilityLabel("Previous \(period.kind.title.lowercased())")
                    Button {
                        model.showToday()
                    } label: {
                        Text(period.title())
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .accessibilityLabel("\(period.title()), show today")
                    Button {
                        model.shiftPeriod(by: 1)
                    } label: {
                        Image(systemName: "chevron.right").frame(width: 30, height: 30)
                    }
                    .disabled(!model.canShiftForward)
                    .accessibilityLabel("Next \(period.kind.title.lowercased())")
                }
                .padding(.horizontal, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .buttonStyle(.plain)
    }
}
