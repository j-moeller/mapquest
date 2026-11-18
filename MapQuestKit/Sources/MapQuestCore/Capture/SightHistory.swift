import Foundation

/// A sight's historical facts, unlocked with its entry: when it was built and
/// opened, its architectural style, who designed and who commissioned it, and the
/// history of the place. The era and the ruler at the time follow from `year`
/// and the place's `Chronicle` (from its sight package).
public struct SightHistory: Codable, Hashable, Sendable {
    /// The year it was built, laid out or founded – the year its era and ruler are taken from.
    public var year: Int?
    /// When it was built, e.g. "1788–1791" or "c. 1230, hall church c. 1380–1470".
    public var built: String?
    /// When it opened, where that adds to `built`, e.g. "1791" or "1996 (museum)".
    public var opened: String?
    /// Architectural styles or periods, e.g. "Neoclassicism".
    public var styles: [String]
    /// Architects, designers and artists.
    public var architects: [String]
    /// Who commissioned it (client, founder).
    public var commissionedBy: [String]
    /// The history of the place (Wikipedia, CC BY-SA 4.0): paragraphs separated by blank lines.
    public var history: String?
    /// Which part of a divided place it lay in (`Chronicle.Division`: Berlin's "east", "west").
    public var sector: String?
    /// The Wikidata item the facts were checked against.
    public var wikidata: URL?
    /// The eras and rulers its year is read in (set when its package is resolved).
    public var chronicle: Chronicle?

    public init(year: Int? = nil, built: String? = nil, opened: String? = nil, styles: [String] = [],
                architects: [String] = [], commissionedBy: [String] = [], history: String? = nil,
                sector: String? = nil, wikidata: URL? = nil, chronicle: Chronicle? = nil) {
        self.year = year
        self.built = built
        self.opened = opened
        self.styles = styles
        self.architects = architects
        self.commissionedBy = commissionedBy
        self.history = history
        self.sector = sector
        self.wikidata = wikidata
        self.chronicle = chronicle
    }

    enum CodingKeys: String, CodingKey {
        case year, built, opened, styles, architects, commissionedBy, history, sector, wikidata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        built = try container.decodeIfPresent(String.self, forKey: .built)
        opened = try container.decodeIfPresent(String.self, forKey: .opened)
        styles = try container.decodeIfPresent([String].self, forKey: .styles) ?? []
        architects = try container.decodeIfPresent([String].self, forKey: .architects) ?? []
        commissionedBy = try container.decodeIfPresent([String].self, forKey: .commissionedBy) ?? []
        history = try container.decodeIfPresent(String.self, forKey: .history)
        sector = try container.decodeIfPresent(String.self, forKey: .sector)
        wikidata = try container.decodeIfPresent(URL.self, forKey: .wikidata)
    }

    public var historyParagraphs: [String] {
        (history ?? "").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The era and the ruler when it was built, in its chronicle.
    public var context: HistoricalContext? {
        guard let year, let chronicle else { return nil }
        return chronicle.context(in: year, sector: sector)
    }

    /// `built` as a phrase: "Built 1788–1791", "Laid out from 1741" ("Erbaut 1788–1791",
    /// "Angelegt ab 1741" with German facts).
    public var builtPhrase: String? {
        guard let built, let first = built.first else { return nil }
        if first.isNumber || built.hasPrefix("c. ") || built.hasPrefix("um ") {
            return LocalizedString("Built", de: "Erbaut")() + " " + built
        }
        return first.uppercased() + built.dropFirst()
    }

    /// e.g. "Built 1788–1791 · Kingdom of Prussia".
    public var epoch: String? {
        let parts = [builtPhrase, context?.era.name].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// While its place was divided: what that time is called and the part it lay in
    /// ("While Berlin was divided", "East Berlin"), if it existed then.
    public var division: (title: String, sector: String)? {
        guard let year, let sector, let division = chronicle?.division, year < division.until,
              let name = division.sectors[sector] else { return nil }
        return (division.title(), name())
    }
}

/// The historical facts of the sights of one or more cities (`<city>-sight-history.json`).
public struct SightHistoryCatalog: Sendable {
    public private(set) var entries: [String: SightHistory]

    public init(entries: [String: SightHistory] = [:]) {
        self.entries = entries
    }

    /// Reads `{"license": …, "entries": {"<sight id>": {year, built, opened, styles, …}}}`
    /// (the build tools' files), each entry read in `chronicle`.
    public static func decode(_ data: Data, chronicle: Chronicle? = nil) throws -> SightHistoryCatalog {
        struct Document: Decodable { var entries: [String: SightHistory] }
        var entries = try JSONDecoder().decode(Document.self, from: data).entries
        for id in entries.keys { entries[id]?.chronicle = chronicle }
        return SightHistoryCatalog(entries: entries)
    }

    public static func merged(_ catalogs: [SightHistoryCatalog]) -> SightHistoryCatalog {
        var entries: [String: SightHistory] = [:]
        for catalog in catalogs {
            entries.merge(catalog.entries) { first, _ in first }
        }
        return SightHistoryCatalog(entries: entries)
    }

    public subscript(id: String) -> SightHistory? { entries[id] }
}
