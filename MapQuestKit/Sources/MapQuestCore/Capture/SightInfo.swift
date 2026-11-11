import Foundation

/// The photo of a sight's entry (Wikimedia Commons), with what its licence requires.
public struct SightPhoto: Codable, Hashable, Sendable {
    /// A 960-pixel thumbnail.
    public var url: URL
    /// The file page (author, licence, full resolution).
    public var page: URL
    public var artist: String
    public var license: String
    public var licenseURL: URL?
}

/// A sight's encyclopedia entry, unlocked by capturing it: the introduction of its
/// Wikipedia article (description and history) and its lead photo.
public struct SightInfo: Codable, Hashable, Sendable {
    /// Title of the Wikipedia article the text comes from.
    public var title: String
    /// Language of the text ("en", or "de" where there is no English article).
    public var language: String
    /// The article (CC BY-SA 4.0).
    public var url: URL
    /// Paragraphs separated by blank lines.
    public var text: String
    public var image: SightPhoto?

    public var paragraphs: [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// The entries of the sights of one or more cities (`<city>-sight-info.json`).
public struct SightInfoCatalog: Sendable {
    public private(set) var entries: [String: SightInfo]

    public init(entries: [String: SightInfo] = [:]) {
        self.entries = entries
    }

    /// Reads `{"license": …, "entries": {"<sight id>": {title, language, url, text, image}}}`.
    public static func decode(_ data: Data) throws -> SightInfoCatalog {
        struct Document: Decodable { var entries: [String: SightInfo] }
        return SightInfoCatalog(entries: try JSONDecoder().decode(Document.self, from: data).entries)
    }

    public static func merged(_ catalogs: [SightInfoCatalog]) -> SightInfoCatalog {
        var entries: [String: SightInfo] = [:]
        for catalog in catalogs {
            entries.merge(catalog.entries) { first, _ in first }
        }
        return SightInfoCatalog(entries: entries)
    }

    public subscript(id: String) -> SightInfo? { entries[id] }
}
