import Foundation

/// A period of a place's history, e.g. the Kingdom of Prussia.
public struct HistoricalEra: Hashable, Sendable, Identifiable, Codable {
    public let id: String
    public let names: LocalizedText
    public let span: LocalizedText
    public let summaries: LocalizedText
    /// Set for eras of one part of a divided place (Berlin 1949–1990: "east", "west").
    public let sector: String?
    /// Whether a monarch ruled (the app shows a crown).
    public let isMonarchy: Bool
    /// First month of the era (`Chronicle.month`).
    public let start: Int

    public var name: String { names() }
    /// e.g. "1701–1871", "since 1990".
    public var years: String { span() }
    /// One or two sentences on the place in that period.
    public var summary: String { summaries() }

    public init(id: String, names: LocalizedText, span: LocalizedText, summaries: LocalizedText, sector: String? = nil,
                isMonarchy: Bool = false, start: Int) {
        self.id = id
        self.names = names
        self.span = span
        self.summaries = summaries
        self.sector = sector
        self.isMonarchy = isMonarchy
        self.start = start
    }

    enum CodingKeys: String, CodingKey {
        case id, names = "name", span = "years", summaries = "summary", sector, isMonarchy = "monarchy", start
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        names = try c.decode(LocalizedText.self, forKey: .names)
        span = try c.decodeIfPresent(LocalizedText.self, forKey: .span) ?? ""
        summaries = try c.decodeIfPresent(LocalizedText.self, forKey: .summaries) ?? ""
        sector = try c.decodeIfPresent(String.self, forKey: .sector)
        isMonarchy = try c.decodeIfPresent(Bool.self, forKey: .isMonarchy) ?? false
        start = try Chronicle.month(parsing: c.decode(String.self, forKey: .start), at: c.codingPath + [CodingKeys.start])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(names, forKey: .names)
        try c.encode(span, forKey: .span)
        try c.encode(summaries, forKey: .summaries)
        try c.encodeIfPresent(sector, forKey: .sector)
        if isMonarchy { try c.encode(true, forKey: .isMonarchy) }
        try c.encode(Chronicle.monthText(start), forKey: .start)
    }
}

/// Who ruled: kings, dukes, presidents, governments – with the era they belong to.
public struct Ruler: Hashable, Sendable, Codable {
    /// The original name and, where they differ, its translations ("Friedrich Wilhelm II.", en "Frederick William II").
    public let names: BilingualName
    public let titles: LocalizedText
    public let reigns: LocalizedText
    public let era: String
    /// First month of the reign (`Chronicle.month`).
    public let start: Int

    /// In the app's language.
    public var name: String { names.primary() }
    /// The original name, next to a translated one.
    public var otherName: String? { names.secondary() }
    public var title: String { titles() }
    /// e.g. "1786–1797".
    public var reign: String { reigns() }

    public init(names: BilingualName, titles: LocalizedText, reigns: LocalizedText, era: String, start: Int) {
        self.names = names
        self.titles = titles
        self.reigns = reigns
        self.era = era
        self.start = start
    }

    enum CodingKeys: String, CodingKey {
        case name, names, nameLanguage, titles = "title", reigns = "reign", era, start
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = BilingualName(local: try c.decode(String.self, forKey: .name),
                              language: try c.decodeIfPresent(String.self, forKey: .nameLanguage) ?? "de",
                              translations: try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:])
        titles = try c.decodeIfPresent(LocalizedText.self, forKey: .titles) ?? ""
        reigns = try c.decodeIfPresent(LocalizedText.self, forKey: .reigns) ?? ""
        era = try c.decode(String.self, forKey: .era)
        start = try Chronicle.month(parsing: c.decode(String.self, forKey: .start), at: c.codingPath + [CodingKeys.start])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(names.local, forKey: .name)
        if !names.translations.isEmpty { try c.encode(names.translations, forKey: .names) }
        if names.localLanguage != "de" { try c.encode(names.localLanguage, forKey: .nameLanguage) }
        try c.encode(titles, forKey: .titles)
        try c.encode(reigns, forKey: .reigns)
        try c.encode(era, forKey: .era)
        try c.encode(Chronicle.monthText(start), forKey: .start)
    }
}

/// The era and the ruler at a point in time.
public struct HistoricalContext: Hashable, Sendable {
    public let era: HistoricalEra
    public let ruler: Ruler?
}

/// A place's eras and rulers, to tell who ruled when a sight was built – part of
/// a sight package (`"chronicles"`), referenced by its sights. Years are read at
/// mid-year: in a year of succession the ruler of July counts.
public struct Chronicle: Hashable, Sendable, Identifiable, Codable {
    /// While a place was divided (Berlin 1949–1990): what to call it and its parts.
    public struct Division: Hashable, Sendable, Codable {
        /// e.g. "While Berlin was divided".
        public var title: LocalizedText
        /// The first year it was no longer divided (1990).
        public var until: Int
        /// The parts by `HistoricalEra.sector` / `SightHistory.sector` ("east": "East Berlin").
        public var sectors: [String: LocalizedText]

        public init(title: LocalizedText, until: Int, sectors: [String: LocalizedText]) {
            self.title = title
            self.until = until
            self.sectors = sectors
        }
    }

    public let id: String
    public let name: LocalizedText
    public let eras: [HistoricalEra]
    public let rulers: [Ruler]
    public let division: Division?

    public init(id: String, name: LocalizedText, eras: [HistoricalEra], rulers: [Ruler], division: Division? = nil) {
        self.id = id
        self.name = name
        self.eras = eras
        self.rulers = rulers
        self.division = division
    }

    /// The era of a year. While a place was divided, the part given by `sector`
    /// (without one: the era of the whole). Nil before the first era.
    public func era(in year: Int, sector: String? = nil) -> HistoricalEra? {
        let time = Self.month(year, 7)
        let begun = eras.filter { $0.start <= time }
        guard let latest = begun.map(\.start).max() else { return nil }
        let current = begun.filter { $0.start == latest }
        return current.first { $0.sector != nil && $0.sector == sector } ?? current.first { $0.sector == nil }
    }

    /// Who ruled in a year (in July of that year).
    public func ruler(in year: Int, sector: String? = nil) -> Ruler? {
        context(in: year, sector: sector)?.ruler
    }

    public func context(in year: Int, sector: String? = nil) -> HistoricalContext? {
        guard let era = era(in: year, sector: sector) else { return nil }
        let time = Self.month(year, 7)
        let ruler = rulers.filter { $0.era == era.id && $0.start <= time }.max { $0.start < $1.start }
        return HistoricalContext(era: era, ruler: ruler)
    }

    /// Position of an era in time (for sorting; parts of a divided place in their order).
    public func order(of era: HistoricalEra) -> Int {
        eras.firstIndex(of: era) ?? eras.count
    }

    /// Month index of a year and month (1–12).
    public static func month(_ year: Int, _ month: Int) -> Int { year * 12 + month - 1 }

    /// "1701-01" (a year alone counts from January).
    static func month(parsing text: String, at path: [CodingKey]) throws -> Int {
        let parts = text.split(separator: "-").map { Int($0) }
        guard let year = parts.first ?? nil, parts.count <= 2, (1...12).contains(parts.count == 2 ? parts[1] ?? 0 : 1) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "expected YYYY-MM, got \(text)"))
        }
        return month(year, parts.count == 2 ? parts[1]! : 1)
    }

    static func monthText(_ month: Int) -> String {
        String(format: "%d-%02d", month / 12, month % 12 + 1)
    }
}
