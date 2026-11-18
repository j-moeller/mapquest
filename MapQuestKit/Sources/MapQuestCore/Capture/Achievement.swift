import Foundation

/// How achievements are grouped in the app.
public enum AchievementGroup: String, Codable, CaseIterable, Sendable {
    case milestones, collections, stories, lines, eras, styles, architects, districts

    /// Groups this app does not know (from newer packages) are stories.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AchievementGroup(rawValue: raw) ?? .stories
    }

    public var title: String {
        let title: LocalizedString
        switch self {
        case .milestones: title = LocalizedString("Milestones", de: "Meilensteine")
        case .collections: title = LocalizedString("Collections", de: "Sammlungen")
        case .stories: title = LocalizedString("Stories", de: "Geschichten")
        case .lines: title = LocalizedString("Lines", de: "Linien")
        case .eras: title = LocalizedString("Through time", de: "Durch die Zeit")
        case .styles: title = LocalizedString("Styles", de: "Baustile")
        case .architects: title = LocalizedString("Master builders", de: "Baumeister")
        case .districts: title = LocalizedString("Districts", de: "Bezirke")
        }
        return title()
    }
}

/// The kind of places an achievement is about.
public enum PlaceKind: String, Codable, Hashable, Sendable {
    /// Captured by photographing them there.
    case sights
    /// Collected by going there.
    case stations
}

/// Which places an achievement asks for. The filters that are set must all match
/// (categories: any of them; styles: any of them; names are compared without a
/// note in parentheses, e.g. "Carl von Gontard (tower)"). `sights` lists the
/// sights instead; `include` and `exclude` adjust either. `count` and `all` are
/// milestones: that many captures of any sights (or stations). Station rules
/// (`places: stations`, `line`, `system`) pick stations: a line's in its order.
public struct AchievementRule: Codable, Hashable, Sendable {
    public var categories: [SightCategory]?
    /// `HistoricalEra.id` of the year it was built, in its city's history (with its sector while Berlin was divided).
    public var era: String?
    public var architect: String?
    public var commissionedBy: String?
    public var styles: [String]?
    public var district: String?
    public var sights: [String]?
    public var include: [String]?
    public var exclude: [String]?
    public var count: Int?
    public var all: Bool?
    /// Sights (default) or stations.
    public var places: PlaceKind?
    /// All stations of this line (e.g. "U2").
    public var line: String?
    /// Stations of this system only.
    public var system: TransitSystem?

    public init(categories: [SightCategory]? = nil, era: String? = nil, architect: String? = nil, commissionedBy: String? = nil,
                styles: [String]? = nil, district: String? = nil, sights: [String]? = nil, include: [String]? = nil,
                exclude: [String]? = nil, count: Int? = nil, all: Bool? = nil, places: PlaceKind? = nil, line: String? = nil,
                system: TransitSystem? = nil) {
        self.categories = categories
        self.era = era
        self.architect = architect
        self.commissionedBy = commissionedBy
        self.styles = styles
        self.district = district
        self.sights = sights
        self.include = include
        self.exclude = exclude
        self.count = count
        self.all = all
        self.places = places
        self.line = line
        self.system = system
    }

    /// A milestone: a number of captures of any sights (or stations).
    public var isMilestone: Bool { count != nil || all == true }

    /// Whether it is about stations rather than sights.
    public var isAboutStations: Bool { places == .stations || line != nil || system != nil }

    var hasFilters: Bool {
        categories != nil || era != nil || architect != nil || commissionedBy != nil || styles != nil || district != nil
    }

    func matches(_ sight: Sight, history: SightHistory?, categories hierarchy: CategoryHierarchy = .core) -> Bool {
        if let categories, !hierarchy.matches(sight.category, any: categories) { return false }
        if let district, sight.district != district { return false }
        if let era, history?.context?.era.id != era { return false }
        if let architect, !(history?.architects ?? []).contains(where: { Self.name($0) == architect }) { return false }
        if let commissionedBy, !(history?.commissionedBy ?? []).contains(where: { Self.name($0) == commissionedBy }) { return false }
        if let styles, !(history?.styles ?? []).contains(where: { styles.contains(Self.name($0)) }) { return false }
        return true
    }

    /// A name without its note: "Carl von Gontard (tower)" → "Carl von Gontard".
    static func name(_ value: String) -> String {
        guard value.hasSuffix(")"), let open = value.range(of: " (", options: .backwards) else { return value }
        return String(value[..<open.lowerBound])
    }
}

/// Something to achieve by capturing sights: all the churches, all buildings of
/// an era or by an architect, every sight of a district, a themed walk, or a
/// number of captures.
public struct Achievement: Codable, Hashable, Identifiable, Sendable {
    /// Unique across all packages (the same ID is the same achievement).
    public var id: String
    public var group: AchievementGroup
    public var titles: LocalizedText
    public var descriptions: LocalizedText
    /// An SF Symbol.
    public var symbol: String
    public var rule: AchievementRule
    /// The package it comes from (set when packages are resolved).
    public var package: String?

    enum CodingKeys: String, CodingKey {
        case id, group, titles = "title", descriptions = "description", symbol, rule
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        group = try container.decodeIfPresent(AchievementGroup.self, forKey: .group) ?? .stories
        titles = try container.decode(LocalizedText.self, forKey: .titles)
        descriptions = try container.decodeIfPresent(LocalizedText.self, forKey: .descriptions) ?? LocalizedText([:])
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "star.fill"
        rule = try container.decode(AchievementRule.self, forKey: .rule)
    }

    public init(id: String, group: AchievementGroup, title: LocalizedText, description: LocalizedText,
                symbol: String, rule: AchievementRule, package: String? = nil) {
        self.id = id
        self.group = group
        self.titles = title
        self.descriptions = description
        self.symbol = symbol
        self.rule = rule
        self.package = package
    }

    /// The title in the app's language.
    public var title: String { titles() }

    /// The description in the app's language.
    public var description: String { descriptions() }
}

/// How far an achievement is: its places, those captured, and when it was completed.
public struct AchievementProgress: Hashable, Identifiable, Sendable {
    public let achievement: Achievement
    /// The places it asks for: sights oldest first (all sights for milestones),
    /// a line's stations in order.
    public let members: [String]
    /// The captured ones among them.
    public let captured: Set<String>
    /// How many captures complete it.
    public let target: Int
    /// When the capture that completed it was made.
    public let completedAt: Date?

    public var id: String { achievement.id }
    public var count: Int { min(captured.count, target) }
    public var isComplete: Bool { captured.count >= target }
    public var remaining: Int { max(0, target - captured.count) }
    public var fraction: Double { target == 0 ? 1 : Double(count) / Double(target) }
}

/// The achievements of the bundled cities, resolved against their sights and
/// stations. Places of remembrance are left out of every achievement.
public struct AchievementBook: Sendable {
    /// An achievement with the sights it asks for.
    public struct Entry: Sendable {
        public let achievement: Achievement
        public let members: [String]
        public let target: Int
    }

    public let entries: [Entry]
    /// Achievements left out because their rule picks fewer than two sights.
    public let skipped: [String]

    /// The achievements of several cities, each resolved against its own sights.
    public static func merged(_ books: [AchievementBook]) -> AchievementBook {
        AchievementBook(entries: books.flatMap(\.entries), skipped: books.flatMap(\.skipped))
    }

    private init(entries: [Entry], skipped: [String]) {
        self.entries = entries
        self.skipped = skipped
    }

    /// Resolves achievements against the sights they may pick (a package's scope).
    public init(achievements: [Achievement], catalog: SightCatalog, histories: SightHistoryCatalog,
                stations: StationCatalog = StationCatalog(), categories: CategoryHierarchy = .core) {
        // Places of remembrance are not part of the game: no achievement asks for them,
        // whatever its rule (`Sight.isPlaceOfRemembrance`).
        // Oldest first, then by name: the order the sights of an achievement are listed in.
        let ordered = catalog.sights.filter { !$0.isPlaceOfRemembrance }.sorted { a, b in
            let ya = histories[a.id]?.year ?? .max, yb = histories[b.id]?.year ?? .max
            return ya != yb ? ya < yb : a.name < b.name
        }
        var entries: [Entry] = []
        var skipped: [String] = []
        var seen: Set<String> = []
        let stationsByName = stations.stations.sorted { ($0.name, $0.system.rawValue) < ($1.name, $1.system.rawValue) }
        for achievement in achievements where seen.insert(achievement.id).inserted {
            let rule = achievement.rule
            if rule.isAboutStations {
                var members: [String]
                if let line = rule.line {
                    members = stations.line(line)?.stations.filter { stations[$0] != nil } ?? []
                } else {
                    members = stationsByName.filter { station in
                        (rule.system.map { station.system == $0 } ?? true) && (rule.district.map { station.district == $0 } ?? true)
                    }.map(\.id)
                }
                members.append(contentsOf: (rule.include ?? []).filter { stations[$0] != nil && !members.contains($0) })
                members.removeAll { (rule.exclude ?? []).contains($0) }
                let target = rule.isMilestone ? (rule.all == true ? members.count : min(rule.count ?? members.count, members.count)) : members.count
                if rule.isMilestone ? target > 0 : members.count >= 2 {
                    entries.append(Entry(achievement: achievement, members: members, target: target))
                } else {
                    skipped.append(achievement.id)
                }
                continue
            }
            if rule.isMilestone {
                let members = ordered.map(\.id)
                let target = rule.all == true ? members.count : min(rule.count ?? members.count, members.count)
                if target > 0 {
                    entries.append(Entry(achievement: achievement, members: members, target: target))
                } else {
                    skipped.append(achievement.id)
                }
                continue
            }
            var picked: Set<String>
            if let listed = rule.sights {
                picked = Set(listed)
            } else if rule.hasFilters {
                picked = Set(ordered.filter { rule.matches($0, history: histories[$0.id], categories: categories) }.map(\.id))
            } else {
                picked = []
            }
            picked.formUnion(rule.include ?? [])
            picked.subtract(rule.exclude ?? [])
            let members = ordered.map(\.id).filter(picked.contains)
            if members.count >= 2 {
                entries.append(Entry(achievement: achievement, members: members, target: members.count))
            } else {
                skipped.append(achievement.id)
            }
        }
        self.entries = entries
        self.skipped = skipped
    }

    public subscript(id: String) -> Entry? { entries.first { $0.achievement.id == id } }

    /// Progress of every achievement for a capture log: photographed sights and
    /// collected stations count (`CaptureLog.captureDates`).
    public func progress(_ log: CaptureLog) -> [AchievementProgress] {
        let captured = log.captureDates
        return entries.map { progress(of: $0, captured: captured) }
    }

    /// `captured`: when each captured place was captured.
    public func progress(of entry: Entry, captured dates: [String: Date]) -> AchievementProgress {
        let captured = entry.members.filter { dates[$0] != nil }
        var completedAt: Date?
        if captured.count >= entry.target {
            // The capture that reached the target.
            let ordered = captured.compactMap { dates[$0] }.sorted()
            completedAt = ordered[entry.target - 1]
        }
        return AchievementProgress(achievement: entry.achievement, members: entry.members, captured: Set(captured),
                                   target: entry.target, completedAt: completedAt)
    }

    /// The achievements complete with these sights captured.
    public func completed(captured: Set<String>) -> Set<String> {
        Set(entries.filter { entry in
            entry.members.lazy.filter(captured.contains).count >= entry.target
        }.map(\.achievement.id))
    }

    /// The achievements that capturing `sights` completes, given everything captured
    /// (including them): complete with them, not without them.
    public func unlocked(by sights: [String], captured: Set<String>) -> [Achievement] {
        let after = completed(captured: captured)
        let before = completed(captured: captured.subtracting(sights))
        return entries.map(\.achievement).filter { after.contains($0.id) && !before.contains($0.id) }
    }
}
