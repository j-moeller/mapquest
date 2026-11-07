import MapQuestCore
import SwiftUI

/// Discovered share of each district of the play area.
struct DistrictsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isComputing = false

    var body: some View {
        List {
            if isComputing && model.districtCoverage.isEmpty {
                HStack {
                    ProgressView()
                    Text("Computing…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.districtCoverage, id: \.name) { district in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(district.name)
                        Spacer()
                        Text(Formatters.percent(district.fraction))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: district.fraction)
                    Text("\(Formatters.area(district.discoveredSquareMeters)) of \(Formatters.area(district.areaSquareMeters))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("\(model.playArea.name) districts")
        .task(id: model.snapshotVersion) {
            isComputing = true
            await model.computeDistrictCoverage()
            isComputing = false
        }
    }
}
