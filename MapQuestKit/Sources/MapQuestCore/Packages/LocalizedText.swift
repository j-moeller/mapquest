import Foundation

/// A text in one or more languages, as sight packages carry it: in JSON either a
/// plain string (the same in every language) or an object of language codes
/// (`{"en": "Berlin Cathedral", "de": "Berliner Dom"}`). Shown in the app's language,
/// else English, else any.
public struct LocalizedText: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    /// Texts by language code; "" for a text in no particular language.
    public var values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public init(_ text: String) {
        values = ["": text]
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public init(en: String, de: String? = nil) {
        var values = ["en": en]
        if let de, de != en { values["de"] = de }
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            values = ["": text]
        } else {
            values = try container.decode([String: String].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if values.count == 1, let text = values[""] {
            try container.encode(text)
        } else {
            try container.encode(values)
        }
    }

    /// The text in a language (the app's), else English, else the neutral or any one.
    public func callAsFunction(_ language: Language = Localization.language) -> String {
        text(in: language.rawValue) ?? values["en"] ?? values[""] ?? values.keys.sorted().first.flatMap { values[$0] } ?? ""
    }

    /// The text written for exactly this language (or language-neutral), if any.
    public func text(in code: String) -> String? {
        values[code] ?? values[""]
    }

    public var isEmpty: Bool { values.values.allSatisfy(\.isEmpty) }
}
