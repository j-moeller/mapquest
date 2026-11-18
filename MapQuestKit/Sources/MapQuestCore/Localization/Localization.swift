import Foundation

/// The languages of the app's text.
public enum Language: String, CaseIterable, Codable, Hashable, Sendable {
    case en, de

    /// The language's own name ("English", "Deutsch").
    public var autonym: String {
        switch self {
        case .en: return "English"
        case .de: return "Deutsch"
        }
    }

    /// The supported language among preferred languages ("de-DE", "en-US", …),
    /// English if none is supported.
    public static func preferred(from languages: [String]) -> Language {
        for identifier in languages {
            let code = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if let code, let language = Language(rawValue: code) { return language }
        }
        return .en
    }
}

/// The language the app shows its text in, and the translations of its text.
///
/// The text of the app is written in English; `tr` looks it up in the table of
/// the current language (German: `de.lproj/*.strings`), which the app registers
/// at launch. Data in both languages (eras, rulers) uses `LocalizedString`.
public enum Localization {
    /// The shared state, behind a lock (read from any thread).
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var language: Language = .en
        var region: String?
        var tables: [Language: [String: String]] = [:]

        func read<T>(_ body: (State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    private static let state = State()

    /// The language of the app's text.
    public static var language: Language {
        get { state.read { $0.language } }
        set { state.read { $0.language = newValue } }
    }

    /// The region for formats (dates, numbers), e.g. "DE"; nil: the language's own.
    public static var formatRegion: String? {
        get { state.read { $0.region } }
        set { state.read { $0.region = newValue } }
    }

    /// The locale for dates and numbers: the app's language with the device's region
    /// ("en_DE": English month names, German conventions where English allows them).
    public static var locale: Locale {
        let (language, region) = state.read { ($0.language, $0.region) }
        return Locale(identifier: region.map { "\(language.rawValue)_\($0)" } ?? language.rawValue)
    }

    /// Adds translations (English text → text in `language`).
    public static func register(_ table: [String: String], for language: Language) {
        state.read { $0.tables[language, default: [:]].merge(table) { _, new in new } }
    }

    /// Removes all translations (tests).
    public static func reset() {
        state.read { $0.tables = [:] }
    }

    /// The text in the current language: its translation, else the English text.
    public static func string(_ key: String, in language: Language? = nil) -> String {
        state.read { state in
            let language = language ?? state.language
            guard language != .en else { return key }
            return state.tables[language]?[key] ?? key
        }
    }

    /// Whether a text has a translation in a language (English always has).
    public static func hasTranslation(_ key: String, in language: Language) -> Bool {
        language == .en || state.read { $0.tables[language]?[key] != nil }
    }

    /// Fills numbered placeholders: "{0} of {1}" with the arguments' descriptions.
    public static func format(_ text: String, _ arguments: [CustomStringConvertible]) -> String {
        guard !arguments.isEmpty, text.contains("{") else { return text }
        var result = text
        for (index, argument) in arguments.enumerated() {
            result = result.replacingOccurrences(of: "{\(index)}", with: argument.description)
        }
        return result
    }
}

/// The app's text in the current language. The key is the English text; numbered
/// placeholders ("{0}", "{1}") take the arguments, in any order in a translation:
/// `tr("{0} of {1} sights captured", captured, total)`.
public func tr(_ english: String, _ arguments: CustomStringConvertible...) -> String {
    Localization.format(Localization.string(english), arguments)
}

/// A text with a count: `one` for 1, `other` otherwise; "{0}" is the count, further
/// arguments follow as "{1}", "{2}". `trn("{0} region", "{0} regions", count)`.
public func trn(_ one: String, _ other: String, _ count: Int, _ arguments: CustomStringConvertible...) -> String {
    Localization.format(Localization.string(count == 1 ? one : other), [count] + arguments)
}

/// A text given in both languages (data of the app: eras, rulers, sectors).
public struct LocalizedString: Hashable, Sendable {
    public let en: String
    public let de: String

    public init(_ en: String, de: String) {
        self.en = en
        self.de = de
    }

    /// The same text in both languages (names).
    public init(_ text: String) {
        self.init(text, de: text)
    }

    public func callAsFunction(_ language: Language = Localization.language) -> String {
        language == .de ? de : en
    }

    /// In the current language.
    public var text: String { self() }
}

/// A place's or person's name in its original language and, where other languages
/// use another, in those. In another language the translated name comes first and
/// the original second ("Brandenburg Gate · Brandenburger Tor", "Frederick the Great ·
/// Friedrich der Große") – unless the original is the one used in that language too
/// and the translation only explains it (`localFirst`: "Hauptbahnhof · Central Station").
public struct BilingualName: Hashable, Sendable {
    /// The original name ("Brandenburger Tor").
    public var local: String
    /// Its language code ("de").
    public var localLanguage: String
    /// Names in other languages, where they differ ("en": "Brandenburg Gate").
    public var translations: [String: String]
    /// In other languages, the original first and the translation as an explanation.
    public var localFirst: Bool

    public init(local: String, language: String, translations: [String: String] = [:], localFirst: Bool = false) {
        self.local = local
        localLanguage = language
        self.translations = translations.filter { !$0.value.isEmpty && $0.value != local && $0.key != language }
        self.localFirst = localFirst
    }

    /// A German original with an English name.
    public init(german: String, english: String? = nil, germanFirst: Bool = false) {
        self.init(local: german, language: "de", translations: english.map { ["en": $0] } ?? [:], localFirst: germanFirst)
    }

    public var german: String { local }
    public var english: String? { translations["en"] }

    /// The name to show in a language.
    public func primary(_ language: Language = Localization.language) -> String {
        guard language.rawValue != localLanguage, !localFirst, let translated = translations[language.rawValue] else { return local }
        return translated
    }

    /// The other name, shown next to it where there is room (in languages other than the original's).
    public func secondary(_ language: Language = Localization.language) -> String? {
        guard language.rawValue != localLanguage, let translated = translations[language.rawValue] else { return nil }
        return localFirst ? translated : local
    }

    /// "Brandenburg Gate (Brandenburger Tor)", or the one name.
    public func full(_ language: Language = Localization.language) -> String {
        guard let secondary = secondary(language) else { return primary(language) }
        return "\(primary(language)) (\(secondary))"
    }
}

/// Reads `.strings` files (`"key" = "value";`, comments, escapes) – the app's
/// translation tables, for checks off the device.
public enum StringsFile {
    public enum ParseError: Error, CustomStringConvertible {
        case unexpected(Character, line: Int)
        case unterminated(line: Int)

        public var description: String {
            switch self {
            case .unexpected(let character, let line): return "unexpected “\(character)” in line \(line)"
            case .unterminated(let line): return "unterminated string or comment from line \(line)"
            }
        }
    }

    /// The entries in order (duplicates kept, for checks).
    public static func entries(_ text: String) throws -> [(key: String, value: String)] {
        let characters = Array(text)
        var index = 0
        var line = 1
        var result: [(String, String)] = []

        func skipSpaceAndComments() throws {
            while index < characters.count {
                let character = characters[index]
                if character == "\n" { line += 1; index += 1; continue }
                if character.isWhitespace { index += 1; continue }
                if character == "/", index + 1 < characters.count {
                    if characters[index + 1] == "/" {
                        while index < characters.count, characters[index] != "\n" { index += 1 }
                        continue
                    }
                    if characters[index + 1] == "*" {
                        let start = line
                        index += 2
                        while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                            if characters[index] == "\n" { line += 1 }
                            index += 1
                        }
                        guard index + 1 < characters.count else { throw ParseError.unterminated(line: start) }
                        index += 2
                        continue
                    }
                }
                return
            }
        }

        func quoted() throws -> String {
            guard index < characters.count, characters[index] == "\"" else {
                throw ParseError.unexpected(index < characters.count ? characters[index] : " ", line: line)
            }
            let start = line
            index += 1
            var value = ""
            while index < characters.count {
                let character = characters[index]
                if character == "\"" { index += 1; return value }
                if character == "\\", index + 1 < characters.count {
                    let next = characters[index + 1]
                    index += 2
                    switch next {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    case "\"": value.append("\"")
                    case "\\": value.append("\\")
                    default: value.append(next)
                    }
                    continue
                }
                if character == "\n" { line += 1 }
                value.append(character)
                index += 1
            }
            throw ParseError.unterminated(line: start)
        }

        func expect(_ expected: Character) throws {
            try skipSpaceAndComments()
            guard index < characters.count, characters[index] == expected else {
                throw ParseError.unexpected(index < characters.count ? characters[index] : " ", line: line)
            }
            index += 1
        }

        while true {
            try skipSpaceAndComments()
            guard index < characters.count else { break }
            let key = try quoted()
            try expect("=")
            try skipSpaceAndComments()
            let value = try quoted()
            try expect(";")
            result.append((key, value))
        }
        return result
    }

    public static func parse(_ text: String) throws -> [String: String] {
        Dictionary(try entries(text), uniquingKeysWith: { _, last in last })
    }

    /// A line of a `.strings` file.
    public static func line(_ key: String, _ value: String) -> String {
        "\"\(escape(key))\" = \"\(escape(value))\";"
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
