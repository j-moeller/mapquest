import Foundation

/// Which part of the city a sight lay in while Berlin was divided (1949–1990).
public enum BerlinSector: String, Codable, Hashable, Sendable {
    case east, west

    public var title: String {
        switch self {
        case .east: return "East Berlin"
        case .west: return "West Berlin"
        }
    }
}

/// A sight's historical facts, unlocked with its entry: when it was built and
/// opened, its architectural style, who designed and who commissioned it, and the
/// history of the place. The era and the ruler at the time follow from `year`
/// (`BerlinHistory`).
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
    /// Where it lay while the city was divided.
    public var sector: BerlinSector?
    /// The Wikidata item the facts were checked against.
    public var wikidata: URL?

    public init(year: Int? = nil, built: String? = nil, opened: String? = nil, styles: [String] = [],
                architects: [String] = [], commissionedBy: [String] = [], history: String? = nil,
                sector: BerlinSector? = nil, wikidata: URL? = nil) {
        self.year = year
        self.built = built
        self.opened = opened
        self.styles = styles
        self.architects = architects
        self.commissionedBy = commissionedBy
        self.history = history
        self.sector = sector
        self.wikidata = wikidata
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
        sector = try container.decodeIfPresent(BerlinSector.self, forKey: .sector)
        wikidata = try container.decodeIfPresent(URL.self, forKey: .wikidata)
    }

    public var historyParagraphs: [String] {
        (history ?? "").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The era and the ruler when it was built (Berlin).
    public var context: HistoricalContext? {
        year.flatMap { BerlinHistory.context(in: $0, sector: sector) }
    }

    /// `built` as a phrase: "Built 1788–1791", "Laid out from 1741".
    public var builtPhrase: String? {
        guard let built, let first = built.first else { return nil }
        if first.isNumber || built.hasPrefix("c. ") { return "Built " + built }
        return first.uppercased() + built.dropFirst()
    }

    /// e.g. "Built 1788–1791 · Kingdom of Prussia".
    public var epoch: String? {
        let parts = [builtPhrase, context?.era.name].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Where it lay during the division, if it existed then.
    public var sectorDuringDivision: BerlinSector? {
        guard let year, year < 1990 else { return nil }
        return sector
    }
}

/// The historical facts of the sights of one or more cities (`<city>-sight-history.json`).
public struct SightHistoryCatalog: Sendable {
    public private(set) var entries: [String: SightHistory]

    public init(entries: [String: SightHistory] = [:]) {
        self.entries = entries
    }

    /// Reads `{"license": …, "entries": {"<sight id>": {year, built, opened, styles, …}}}`.
    public static func decode(_ data: Data) throws -> SightHistoryCatalog {
        struct Document: Decodable { var entries: [String: SightHistory] }
        return SightHistoryCatalog(entries: try JSONDecoder().decode(Document.self, from: data).entries)
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
