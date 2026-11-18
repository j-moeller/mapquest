import MapQuestCore
import SwiftUI

/// Menu › Map icons: which stations and sights the 2D and 3D maps show.
struct MapIconsView: View {
    @EnvironmentObject private var captures: CaptureModel

    var body: some View {
        Form {
            Section {
                ForEach(TransitSystem.allCases, id: \.self) { system in
                    Toggle(isOn: shows(system)) {
                        row(system.title, count: captures.stations.stations.filter { $0.system == system }.count) {
                            AchievementSymbol(name: system == .ubahn ? "u.square.fill" : "s.circle.fill", size: 15)
                                .frame(width: 28)
                        }
                    }
                }
            } header: {
                Text(tr("Stations"))
            }

            Section {
                Toggle(isOn: showsQuestionMarks) {
                    row(tr("Question marks"), count: captures.nearbyCount) {
                        SightBadge(category: .landmark, captured: false, nearby: true, size: 28)
                    }
                }
                ForEach(categories(remembrance: false), id: \.self) { category in
                    Toggle(isOn: shows(category)) {
                        row(category.title, count: count(of: category)) {
                            SightBadge(category: category, captured: true, size: 28)
                        }
                    }
                }
            } header: {
                Text(tr("Sights"))
            } footer: {
                Text(tr("Question marks are sights you came near; they keep their kind to themselves, so they have a switch of their own."))
            }

            Section {
                ForEach(categories(remembrance: true), id: \.self) { category in
                    Toggle(isOn: shows(category)) {
                        row(category.title, count: count(of: category)) {
                            SightBadge(category: category, captured: false, size: 28)
                        }
                    }
                }
            } header: {
                Text(tr("Places of remembrance"))
            }

            Section {
                Button(tr("Show all icons")) {
                    captures.iconFilter = MapIconFilter()
                }
                .disabled(captures.iconFilter.hiddenCount == 0)
                Button(tr("Hide all sights")) {
                    captures.iconFilter.hiddenCategories = Set(SightCategory.allCases)
                    captures.iconFilter.hidesQuestionMarks = true
                }
            } footer: {
                Text(tr("Hidden icons are left off the 2D and 3D maps. The list of sights still shows everything, and a sight or station you show on the map from there appears anyway."))
            }
        }
        .navigationTitle(tr("Map icons"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// An icon, a name and how many there are.
    private func row<Icon: View>(_ title: String, count: Int, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 12) {
            icon()
            Text(title)
            Spacer(minLength: 8)
            Text(Formatters.number(count))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// The categories that have sights, in their order (with the categories packages declare under them).
    private func categories(remembrance: Bool) -> [SightCategory] {
        SightCategory.allCases.filter { $0.isRemembrance == remembrance && count(of: $0) > 0 }
    }

    private func count(of category: SightCategory) -> Int {
        captures.catalog.sights.filter { $0.category.core == category }.count
    }

    private func shows(_ system: TransitSystem) -> Binding<Bool> {
        Binding(
            get: { !captures.iconFilter.hiddenSystems.contains(system) },
            set: { shown in
                if shown { captures.iconFilter.hiddenSystems.remove(system) } else { captures.iconFilter.hiddenSystems.insert(system) }
            }
        )
    }

    private func shows(_ category: SightCategory) -> Binding<Bool> {
        Binding(
            get: { !captures.iconFilter.hiddenCategories.contains(category) },
            set: { shown in
                if shown { captures.iconFilter.hiddenCategories.remove(category) } else { captures.iconFilter.hiddenCategories.insert(category) }
            }
        )
    }

    private var showsQuestionMarks: Binding<Bool> {
        Binding(get: { !captures.iconFilter.hidesQuestionMarks }, set: { captures.iconFilter.hidesQuestionMarks = !$0 })
    }
}
