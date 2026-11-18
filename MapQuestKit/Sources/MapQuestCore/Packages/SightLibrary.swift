import Foundation

/// The installed sight packages, resolved into one world (docs/09-sight-packages.md):
///
/// * **One package per ID**: of the same package the newest version counts.
/// * **Order**: newer packages first (by version, then ID). Where several packages
///   define the same sight, achievement, chronicle, station, line, chapter or walk
///   (the same ID), the first in this order is used – IDs are global, so the same ID
///   is the same thing, and the newest description of it wins.
/// * **The same place under other IDs**: a sight naming another in `sameAs`, or with
///   the same Wikidata item as one before it, is merged into that one (`aliases`);
///   rules and walks that name it count the merged sight.
/// * **Categories**: the core vocabulary plus what packages declare, each under a
///   parent (`CategoryHierarchy`); a rule for "church" takes in a declared "chapel".
/// * **Scope**: a package's achievements pick from its own sights and those of the
///   packages it includes (transitively) – the Berlin churches package's "all
///   churches" never counts Braunschweig's, the Berlin package's milestones count
///   everything Berlin includes.
/// * **Regions**: each package names its region; the app groups by it.
public struct SightLibrary: Sendable {
    public enum Severity: String, Sendable { case warning, error }

    /// Something the resolution noticed, per package.
    public struct Issue: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// An included package is not installed.
            case missingInclude(String)
            /// A sight's category is neither core nor declared (shown as a landmark).
            case unknownCategory(category: String, sight: String)
            /// A sight names a chronicle no package has.
            case unknownChronicle(chronicle: String, sight: String)
            /// An achievement, chapter or walk names a sight or station outside its package's scope.
            case unknownPlace(place: String, in: String)
            /// An achievement's era is in none of the chronicles of its scope.
            case unknownEra(era: String, achievement: String)
            /// An achievement picks fewer than two places and is left out.
            case skippedAchievement(String)
            /// A chapter names a sight that is not a place of remembrance.
            case notRemembrance(sight: String, chapter: String)
            /// A sight was merged into another (same place).
            case merged(sight: String, into: String)
        }

        public var package: String
        public var severity: Severity
        public var kind: Kind
    }

    /// A region the packages describe ("berlin").
    public struct Region: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: LocalizedText
        public var bounds: SightPackage.Bounds?
    }

    /// The packages in resolution order (newest first).
    public let packages: [SightPackage]
    public let catalog: SightCatalog
    public let categories: CategoryHierarchy
    public let chronicles: [String: Chronicle]
    public let stations: StationCatalog
    public let achievements: AchievementBook
    public let regions: [Region]
    /// Merged sight IDs → the ID they count as.
    public let aliases: [String: String]
    public let issues: [Issue]
    /// The region of each sight, station and achievement.
    public let regionOfSight: [String: String]
    public let regionOfStation: [String: String]
    public let regionOfAchievement: [String: String]
    /// The packages describing each sight (resolution order).
    public let packagesOfSight: [String: [String]]
    private let infosByLanguage: [Language: SightInfoCatalog]
    private let historiesByLanguage: [Language: SightHistoryCatalog]
    private let remembranceByLanguage: [Language: RemembranceGuide]
    private let scopes: [String: Set<String>]

    public init(packages input: [SightPackage]) {
        // One package per ID: the newest version.
        var newest: [String: SightPackage] = [:]
        for package in input {
            if let other = newest[package.id], !SightPackage.isVersion(package.version, newerThan: other.version) { continue }
            newest[package.id] = package
        }
        let packages = newest.values.sorted {
            $0.version != $1.version ? SightPackage.isVersion($0.version, newerThan: $1.version) : $0.id < $1.id
        }
        self.packages = packages
        var issues: [Issue] = []
        func note(_ package: String, _ severity: Severity, _ kind: Issue.Kind) {
            issues.append(Issue(package: package, severity: severity, kind: kind))
        }

        let categories = CategoryHierarchy(packages.flatMap { $0.categories ?? [] })
        self.categories = categories
        var chronicles: [String: Chronicle] = [:]
        for chronicle in packages.flatMap({ $0.chronicles ?? [] }) where chronicles[chronicle.id] == nil {
            chronicles[chronicle.id] = chronicle
        }
        self.chronicles = chronicles

        // Sights: the first description of each ID, and who describes it.
        var winners: [(sight: SightPackage.PackageSight, package: SightPackage)] = []
        var winnerIndex: [String: Int] = [:]
        var packagesOfSight: [String: [String]] = [:]
        for package in packages {
            for sight in package.sights ?? [] {
                packagesOfSight[sight.id, default: []].append(package.id)
                guard winnerIndex[sight.id] == nil else { continue }
                winnerIndex[sight.id] = winners.count
                winners.append((sight, package))
                if !categories.isKnown(sight.category) {
                    note(package.id, .warning, .unknownCategory(category: sight.category.rawValue, sight: sight.id))
                }
            }
        }

        // The same place under other IDs: `sameAs`, then the same Wikidata item.
        var aliases: [String: String] = [:]
        for (sight, package) in winners {
            for target in sight.sameAs ?? [] where target != sight.id && winnerIndex[target] != nil && aliases[target] != sight.id {
                aliases[sight.id] = target
                note(package.id, .warning, .merged(sight: sight.id, into: target))
                break
            }
        }
        var byWikidata: [String: String] = [:]
        for (sight, package) in winners where aliases[sight.id] == nil {
            guard let item = sight.wikidata?.uppercased(), !item.isEmpty else { continue }
            if let first = byWikidata[item] {
                aliases[sight.id] = first
                note(package.id, .warning, .merged(sight: sight.id, into: first))
            } else {
                byWikidata[item] = sight.id
            }
        }
        func canonical(_ id: String) -> String {
            var current = id
            var seen: Set<String> = [id]
            while let next = aliases[current], seen.insert(next).inserted { current = next }
            return current
        }
        aliases = Dictionary(uniqueKeysWithValues: aliases.keys.map { ($0, canonical($0)) })
        self.aliases = aliases
        for (alias, target) in aliases {
            packagesOfSight[target, default: []].append(contentsOf: packagesOfSight[alias] ?? [])
        }
        self.packagesOfSight = packagesOfSight

        // The sights, their regions, entries and facts in every language.
        var sights: [Sight] = []
        var regionOfSight: [String: String] = [:]
        var infos: [Language: [String: SightInfo]] = [:]
        var histories: [Language: [String: SightHistory]] = [:]
        for (described, package) in winners where aliases[described.id] == nil {
            let names = BilingualName(local: described.name, language: described.nameLanguage ?? package.language ?? "de",
                                      translations: described.names ?? [:])
            sights.append(Sight(id: described.id, names: names, category: described.category, latitude: described.latitude,
                                longitude: described.longitude, radius: described.radius ?? 40, district: described.district,
                                isPlaceOfRemembrance: categories.isRemembrance(described.category)))
            if let region = package.region?.id { regionOfSight[described.id] = region }
            let chronicleID = described.chronicle ?? package.chronicles?.first?.id ?? package.region?.id
            let chronicle = chronicleID.flatMap { chronicles[$0] }
            if let chronicleID, chronicle == nil, described.facts?.year != nil {
                note(package.id, .warning, .unknownChronicle(chronicle: chronicleID, sight: described.id))
            }
            for language in Language.allCases {
                if let entries = described.entry,
                   let pair = entries[language.rawValue].map({ (language.rawValue, $0) }) ?? entries["en"].map({ ("en", $0) })
                                ?? entries.sorted(by: { $0.key < $1.key }).first.map({ ($0.key, $0.value) }) {
                    var info = pair.1
                    if info.language.isEmpty { info.language = pair.0 }
                    infos[language, default: [:]][described.id] = info
                }
                if let facts = described.facts {
                    let texts = facts.localized[language.rawValue] ?? facts.localized["en"]
                        ?? facts.localized.sorted(by: { $0.key < $1.key }).first?.value ?? SightPackage.FactTexts()
                    histories[language, default: [:]][described.id] = SightHistory(
                        year: facts.year, built: texts.built, opened: texts.opened, styles: texts.styles ?? [],
                        architects: texts.architects ?? [], commissionedBy: texts.commissionedBy ?? [], history: texts.history,
                        sector: facts.sector, wikidata: facts.wikidata, chronicle: chronicle
                    )
                }
            }
        }
        let catalog = SightCatalog(sights: sights)
        self.catalog = catalog
        self.regionOfSight = regionOfSight
        infosByLanguage = infos.mapValues { SightInfoCatalog(entries: $0) }
        historiesByLanguage = histories.mapValues { SightHistoryCatalog(entries: $0) }

        // Stations and lines: the first of each ID.
        var stationList: [Station] = []
        var lines: [TransitLine] = []
        var regionOfStation: [String: String] = [:]
        var stationIDs: Set<String> = [], lineIDs: Set<String> = []
        for package in packages {
            for station in package.transit?.stations ?? [] where stationIDs.insert(station.id).inserted {
                stationList.append(station)
                if let region = package.region?.id { regionOfStation[station.id] = region }
            }
            for line in package.transit?.lines ?? [] where lineIDs.insert(line.id).inserted { lines.append(line) }
        }
        let stations = StationCatalog(stations: stationList, lines: lines)
        self.stations = stations
        self.regionOfStation = regionOfStation

        // Scopes: a package's own sights and stations and those of what it includes.
        let byID = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
        var scopes: [String: Set<String>] = [:]
        func scope(_ id: String, visiting: Set<String> = []) -> Set<String> {
            if let known = scopes[id] { return known }
            guard let package = byID[id], !visiting.contains(id) else { return [] }
            var result = Set((package.sights ?? []).map { canonical($0.id) })
            result.formUnion((package.transit?.stations ?? []).map(\.id))
            for included in package.includes ?? [] {
                result.formUnion(scope(included, visiting: visiting.union([id])))
            }
            scopes[id] = result
            return result
        }
        for package in packages {
            for included in package.includes ?? [] where byID[included] == nil {
                note(package.id, .warning, .missingInclude(included))
            }
            _ = scope(package.id)
        }
        self.scopes = scopes

        // Achievements: the first of each ID, resolved against its package's scope.
        let englishHistories = historiesByLanguage[.en] ?? SightHistoryCatalog()
        var books: [AchievementBook] = []
        var regionOfAchievement: [String: String] = [:]
        var achievementIDs: Set<String> = []
        for package in packages {
            var own: [Achievement] = []
            for var achievement in package.achievements ?? [] where achievementIDs.insert(achievement.id).inserted {
                achievement.package = package.id
                achievement.rule.sights = achievement.rule.sights?.map(canonical)
                achievement.rule.include = achievement.rule.include?.map(canonical)
                achievement.rule.exclude = achievement.rule.exclude?.map(canonical)
                own.append(achievement)
                if let region = package.region?.id { regionOfAchievement[achievement.id] = region }
            }
            guard !own.isEmpty else { continue }
            let inScope = scopes[package.id] ?? []
            let scopedCatalog = SightCatalog(sights: catalog.sights.filter { inScope.contains($0.id) })
            let scopedStations = StationCatalog(stations: stations.stations.filter { inScope.contains($0.id) }, lines: stations.lines)
            let book = AchievementBook(achievements: own, catalog: scopedCatalog, histories: englishHistories,
                                       stations: scopedStations, categories: categories)
            books.append(book)
            let scopeEras = Set(scopedCatalog.sights.compactMap { englishHistories[$0.id]?.chronicle }.flatMap { $0.eras.map(\.id) })
            for achievement in own {
                let rule = achievement.rule
                for place in (rule.sights ?? []) + (rule.include ?? []) where !inScope.contains(place) {
                    note(package.id, .warning, .unknownPlace(place: place, in: achievement.id))
                }
                if let era = rule.era, !scopeEras.contains(era) {
                    note(package.id, .warning, .unknownEra(era: era, achievement: achievement.id))
                }
            }
            for skipped in book.skipped { note(package.id, .warning, .skippedAchievement(skipped)) }
        }
        achievements = .merged(books)
        self.regionOfAchievement = regionOfAchievement

        // Places of remembrance: chapters and walks by ID, in every language.
        var chapters: [(SightPackage.Remembrance.Chapter, String)] = []
        var tours: [(SightPackage.Remembrance.Tour, String)] = []
        var chapterIDs: Set<String> = [], tourIDs: Set<String> = []
        for package in packages {
            for chapter in package.remembrance?.chapters ?? [] where chapterIDs.insert(chapter.id).inserted {
                chapters.append((chapter, package.id))
                for place in chapter.places {
                    let id = canonical(place.sight)
                    if catalog[id] == nil {
                        note(package.id, .warning, .unknownPlace(place: place.sight, in: chapter.id))
                    } else if catalog[id]?.isPlaceOfRemembrance == false {
                        note(package.id, .warning, .notRemembrance(sight: id, chapter: chapter.id))
                    }
                }
            }
            for tour in package.remembrance?.tours ?? [] where tourIDs.insert(tour.id).inserted {
                tours.append((tour, package.id))
                for stop in tour.stops where catalog[canonical(stop)] == nil {
                    note(package.id, .warning, .unknownPlace(place: stop, in: tour.id))
                }
            }
        }
        var guides: [Language: RemembranceGuide] = [:]
        for language in Language.allCases {
            guides[language] = RemembranceGuide(
                chapters: chapters.map { chapter, _ in
                    RemembranceGuide.Chapter(
                        id: chapter.id, title: chapter.title(language), years: chapter.years?(language) ?? "",
                        text: chapter.text(language),
                        places: chapter.places.compactMap { place in
                            let id = canonical(place.sight)
                            return catalog[id] == nil ? nil : RemembranceGuide.Place(sight: id, remembers: place.remembers(language))
                        }
                    )
                },
                tours: tours.map { tour, _ in
                    RemembranceGuide.Tour(id: tour.id, title: tour.title(language), text: tour.text(language),
                                          stops: tour.stops.map(canonical).filter { catalog[$0] != nil })
                }
            )
        }
        remembranceByLanguage = guides

        // Regions: as the packages name them, with the bounds of their sights where they give none.
        var regions: [Region] = []
        for package in packages {
            guard let region = package.region, !regions.contains(where: { $0.id == region.id }) else { continue }
            regions.append(Region(id: region.id, name: region.name, bounds: region.bounds))
        }
        for index in regions.indices where regions[index].bounds == nil {
            let members = catalog.sights.filter { regionOfSight[$0.id] == regions[index].id }
            guard let first = members.first else { continue }
            regions[index].bounds = members.dropFirst().reduce(
                SightPackage.Bounds(south: first.latitude, west: first.longitude, north: first.latitude, east: first.longitude)
            ) { $0.union(.init(south: $1.latitude, west: $1.longitude, north: $1.latitude, east: $1.longitude)) }
        }
        self.regions = regions
        self.issues = issues
    }

    /// The sights' entries in a language (English where a sight has none in it).
    public func infos(_ language: Language) -> SightInfoCatalog { infosByLanguage[language] ?? SightInfoCatalog() }

    /// The sights' facts in a language (English where a sight has none in it).
    public func histories(_ language: Language) -> SightHistoryCatalog { historiesByLanguage[language] ?? SightHistoryCatalog() }

    /// The places of remembrance in a language.
    public func remembrance(_ language: Language) -> RemembranceGuide { remembranceByLanguage[language] ?? RemembranceGuide() }

    /// The sights and stations a package's achievements pick from.
    public func scope(of package: String) -> Set<String> { scopes[package] ?? [] }

    /// The ID a sight counts as (merged sights: the one they were merged into).
    public func canonical(_ id: String) -> String { aliases[id] ?? id }

    /// Issues of one package.
    public func issues(of package: String) -> [Issue] { issues.filter { $0.package == package } }
}
