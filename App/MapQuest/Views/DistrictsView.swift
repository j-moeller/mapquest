import MapQuestCore
import SwiftUI

/// Discovered share of each bundled city and its districts.
struct DistrictsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isComputing = false

    var body: some View {
        List {
            if isComputing && model.districtCoverage.isEmpty {
                HStack {
                    ProgressView()
                    Text(tr("Computing…"))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.districtCoverage) { city in
                Section {
                    if city.districts.isEmpty {
                        // A city without bundled districts (Peine): the city itself.
                        CoverageRow(coverage: city.city)
                    }
                    ForEach(city.districts, id: \.name) { district in
                        CoverageRow(coverage: district)
                    }
                } header: {
                    Text(city.city.name)
                } footer: {
                    Text(tr(
                        "{0}: {1} – {2} of {3}", city.city.name, Formatters.percent(city.city.fraction),
                        Formatters.area(city.city.discoveredSquareMeters), Formatters.area(city.city.areaSquareMeters)
                    ))
                }
            }
        }
        .navigationTitle(tr("Cities and districts"))
        .safeAreaInset(edge: .top) {
            Picker(tr("Discovery"), selection: $model.selectedLayer) {
                ForEach(MapLayer.allCases) { layer in
                    Text(layer.title).tag(layer)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .task(id: "\(model.selectedLayer.rawValue)-\(model.state(model.selectedLayer).version)") {
            isComputing = true
            await model.computeDistrictCoverage()
            isComputing = false
        }
    }
}

private struct CoverageRow: View {
    let coverage: AreaCoverage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(coverage.name)
                Spacer()
                Text(Formatters.percent(coverage.fraction))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: coverage.fraction)
            Text(tr("{0} of {1}", Formatters.area(coverage.discoveredSquareMeters), Formatters.area(coverage.areaSquareMeters)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
