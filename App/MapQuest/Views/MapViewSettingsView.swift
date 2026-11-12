import MapQuestCore
import SwiftUI

/// How the map is shown: 2D map or 3D scene, fog of war or heatmap, the layer,
/// the time span (all time, or a day, week, month or year to step through) and
/// the map style. Opened from the menu, or from the note on the map.
struct MapViewSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("ContentView.mode") private var mode: MapMode = .twoD

    var body: some View {
        Form {
            Section {
                Picker(tr("Map"), selection: $mode) {
                    ForEach(MapMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(tr("Map"))
            } footer: {
                Text(mode == .twoD
                     ? tr("The 2D map with the fog of war over everything not discovered yet.")
                     : tr("The 3D scene of the buildings around you, with what you have seen between them (the line of sight)."))
            }

            if mode == .twoD {
                Section {
                    Picker(tr("Show"), selection: $model.aggregate) {
                        ForEach(MapAggregate.allCases) { aggregate in
                            Text(aggregate.title).tag(aggregate)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker(tr("Discovered by"), selection: $model.selectedLayer) {
                        ForEach(MapLayer.allCases) { layer in
                            Text(layer.title).tag(layer)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(tr("Display"))
                } footer: {
                    Text(tr("The fog of war lifts where you have been; the heatmap shows how often you were there. Radius: everything around your positions. Line of sight: what you could see between the buildings."))
                }
            }

            Section {
                Picker(tr("Time span"), selection: Binding(get: { model.periodKind }, set: { model.showPeriod($0) })) {
                    Text(tr("All time")).tag(PeriodKind?.none)
                    ForEach(PeriodKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(PeriodKind?.some(kind))
                    }
                }
                .pickerStyle(.segmented)
                if let period = model.currentPeriod {
                    HStack {
                        Button {
                            model.shiftPeriod(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 36, height: 30)
                        }
                        .accessibilityLabel(period.kind.previousTitle)
                        Spacer()
                        Text(period.title())
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                        Button {
                            model.shiftPeriod(by: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .frame(width: 36, height: 30)
                        }
                        .disabled(!model.canShiftForward)
                        .accessibilityLabel(period.kind.nextTitle)
                    }
                    .buttonStyle(.borderless)
                    Button(tr("Show today")) { model.showToday() }
                }
            } header: {
                Text(tr("Time"))
            } footer: {
                Text(tr("All time shows everything you have discovered. A day, week, month or year shows what you saw in it."))
            }

            Section {
                Picker(tr("Map style"), selection: Binding(
                    get: { model.debug.baseMap },
                    set: { style in
                        var settings = model.debug
                        settings.baseMap = style
                        Task { await model.applyDebugSettings(settings) }
                    }
                )) {
                    ForEach(BaseMapStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                // Not "Style": that is the architectural style elsewhere (another German word).
                Text(tr("Base map"))
            }
        }
        .navigationTitle(tr("Map view"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
