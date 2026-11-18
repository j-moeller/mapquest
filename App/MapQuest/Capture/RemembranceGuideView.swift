import CoreLocation
import MapQuestCore
import SwiftUI

/// The places of remembrance, outside the game: a short history in chapters,
/// each with the places that remember it, and walks between them. No counts, no
/// progress, nothing to collect – only what each place remembers.
struct RemembranceSections: View {
    @EnvironmentObject private var captures: CaptureModel

    var body: some View {
        let guide = captures.remembrance(in: captures.cityID)
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("{0} remembers", captures.currentCity?.name ?? ""))
                    .font(.title3.weight(.semibold))
                Text(tr("Memorials, memorial sites and cemeteries keep the memory of the people who were persecuted, murdered and killed in war, and of those who resisted. They are not part of the game: there is nothing to capture or collect, and every entry is open. Read about them here, or visit them on a walk – in your own time, and with respect."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }

        ForEach(guide.chapters) { chapter in
            Section {
                Text(chapter.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(chapter.places, id: \.sight) { place in
                    if let sight = captures.catalog[place.sight] {
                        RemembrancePlaceRow(sight: sight, remembers: place.remembers)
                    }
                }
            } header: {
                RemembranceChapterHeader(title: chapter.title, years: chapter.years)
            }
        }

        let others = otherPlaces(besides: guide)
        if !others.isEmpty {
            Section {
                ForEach(others, id: \.id) { sight in
                    RemembrancePlaceRow(sight: sight, remembers: captures.infos[sight.id]?.paragraphs.first)
                }
            } header: {
                RemembranceChapterHeader(title: tr("Other places of remembrance"), years: nil)
            }
        }

        if !guide.tours.isEmpty {
            Section {
                ForEach(guide.tours) { tour in
                    NavigationLink {
                        RemembranceTourView(tour: tour)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tour.title)
                            Text(tourSummary(tour))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                RemembranceChapterHeader(title: tr("Walks"), years: nil)
            } footer: {
                Text(tr("Places of remembrance close to each other, in an order that tells their history."))
            }
        }
    }

    /// Places of remembrance of the city the guide does not tell about.
    private func otherPlaces(besides guide: RemembranceGuide) -> [Sight] {
        let told = Set(guide.chapters.flatMap { $0.places.map(\.sight) })
        return captures.sights(in: captures.cityID)
            .filter { $0.isPlaceOfRemembrance && !told.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    /// "4 places · about 2.4 km".
    private func tourSummary(_ tour: RemembranceGuide.Tour) -> String {
        let stops = tour.stops.compactMap { captures.catalog[$0] }
        let length = RemembranceGuide.length(of: stops.map(\.coordinate))
        return trn("{0} place · about {1}", "{0} places · about {1}", stops.count, Formatters.distance(length))
    }
}

/// A chapter's title and years, in the list's section header.
struct RemembranceChapterHeader: View {
    let title: String
    let years: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            if let years {
                Text(years)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A place of remembrance: its name, what it remembers, how far it is and – once
/// you were there – when. Opens its entry.
struct RemembrancePlaceRow: View {
    @EnvironmentObject private var captures: CaptureModel
    @EnvironmentObject private var tracker: LocationTracker
    let sight: Sight
    let remembers: String?
    /// The stop's number on a walk.
    var number: Int?

    var body: some View {
        NavigationLink {
            SightEntryView(sight: sight)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if let number {
                    Text("\(number)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.remembrance, in: Circle())
                } else {
                    SightBadge(category: sight.category, captured: false, size: 30)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(sight.name)
                        .foregroundStyle(.primary)
                    if let remembers {
                        Text(remembers)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityHint(tr("Opens its entry"))
    }

    /// "1.2 km away · you were here on 3 Nov 2026".
    private var detail: String? {
        var parts: [String] = []
        if let location = tracker.lastLocation {
            let meters = location.distance(from: CLLocation(latitude: sight.latitude, longitude: sight.longitude))
            parts.append(tr("{0} away", Formatters.away(meters)))
        }
        if let record = captures.log.records[sight.id] {
            parts.append(tr("you were here on {0}", Formatters.date(record.capturedAt)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A walk between places of remembrance: what it tells, its stops in order, and
/// the first stop on the map.
struct RemembranceTourView: View {
    @EnvironmentObject private var captures: CaptureModel
    let tour: RemembranceGuide.Tour

    var body: some View {
        let stops = tour.stops.compactMap { captures.catalog[$0] }
        let length = RemembranceGuide.length(of: stops.map(\.coordinate))
        List {
            Section {
                Text(tour.text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(tr("Between the places"), value: tr("about {0}", Formatters.distance(length)))
            } footer: {
                Text(tr("As the crow flies; the way on foot is longer. Take your time at each place."))
            }
            Section {
                ForEach(Array(stops.enumerated()), id: \.element.id) { index, sight in
                    RemembrancePlaceRow(sight: sight, remembers: captures.remembrance.remembers(sight.id), number: index + 1)
                }
            } header: {
                Text(tr("The places"))
            }
            if let first = stops.first {
                Section {
                    Button {
                        captures.show(first)
                    } label: {
                        Label(tr("Show the first place on the map"), systemImage: "map")
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle(tour.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
