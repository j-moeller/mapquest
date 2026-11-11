import Foundation

/// How achievements are grouped in the app.
public enum AchievementGroup: String, Codable, CaseIterable, Sendable {
    case milestones, collections, stories, eras, styles, architects, districts

    public var title: String {
        switch self {
        case .milestones: return "Milestones"
        case .collections: return "Collections"
        case .stories: return "Stories"
        case .eras: return "Through time"
        case .styles: return "Styles"
        case .architects: return "Master builders"
        case .districts: return "Districts"
        }
    }
}

/// Which sights an achievement asks for. The filters that are set must all match
/// (categories: any of them; styles: any of them; names are compared without a
/// note in parentheses, e.g. "Carl von Gontard (tower)"). `sights` lists the
/// sights instead; `include` and `exclude` adjust either. `count` and `all` are
/// milestones: that many captures of any sights.
public struct AchievementRule: Codable, Hashable, Sendable {
    public var categories: [SightCategory]?
    /// `HistoricalEra.id` of the year it was built (with its sector while Berlin was divided).
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

    public init(categories: [SightCategory]? = nil, era: String? = nil, architect: String? = nil, commissionedBy: String? = nil,
                styles: [String]? = nil, district: String? = nil, sights: [String]? = nil, include: [String]? = nil,
                exclude: [String]? = nil, count: Int? = nil, all: Bool? = nil) {
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
    }

    /// A milestone: a number of captures of any sights.
    public var isMilestone: Bool { count != nil || all == true }

    var hasFilters: Bool {
        categories != nil || era != nil || architect != nil || commissionedBy != nil || styles != nil || district != nil
    }

    func matches(_ sight: Sight, history: SightHistory?) -> Bool {
        if let categories, !categories.contains(sight.category) { return false }
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
    public var id: String
    public var group: AchievementGroup
    public var title: String
    public var description: String
    /// An SF Symbol.
    public var symbol: String
    public var rule: AchievementRule

    public init(id: String, group: AchievementGroup, title: String, description: String, symbol: String, rule: AchievementRule) {
        self.id = id
        self.group = group
        self.title = title
        self.description = description
        self.symbol = symbol
        self.rule = rule
    }

    /// Reads `{"achievements": [{id, group, title, description, symbol, rule}]}` (`<city>-achievements.json`).
    public static func decodeList(_ data: Data) throws -> [Achievement] {
        struct Document: Decodable { var achievements: [Achievement] }
        return try JSONDecoder().decode(Document.self, from: data).achievements
    }
}

/// How far an achievement is: its sights, those captured, and when it was completed.
public struct AchievementProgress: Hashable, Identifiable, Sendable {
    public let achievement: Achievement
    /// The sights it asks for, oldest first (all sights for milestones).
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

/// The achievements of the bundled cities, resolved against their sights.
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

    public init(achievements: [Achievement], catalog: SightCatalog, histories: SightHistoryCatalog) {
        // Oldest first, then by name: the order the sights of an achievement are listed in.
        let ordered = catalog.sights.sorted { a, b in
            let ya = histories[a.id]?.year ?? .max, yb = histories[b.id]?.year ?? .max
            return ya != yb ? ya < yb : a.name < b.name
        }
        var entries: [Entry] = []
        var skipped: [String] = []
        var seen: Set<String> = []
        for achievement in achievements where seen.insert(achievement.id).inserted {
            let rule = achievement.rule
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
                picked = Set(ordered.filter { rule.matches($0, history: histories[$0.id]) }.map(\.id))
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

    /// Progress of every achievement for a capture log.
    public func progress(_ log: CaptureLog) -> [AchievementProgress] {
        entries.map { progress(of: $0, records: log.records) }
    }

    public func progress(of entry: Entry, records: [String: CaptureRecord]) -> AchievementProgress {
        let captured = entry.members.filter { records[$0] != nil }
        var completedAt: Date?
        if captured.count >= entry.target {
            // The capture that reached the target.
            let dates = captured.compactMap { records[$0]?.capturedAt }.sorted()
            completedAt = dates[entry.target - 1]
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
