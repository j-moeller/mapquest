import Foundation
import XCTest
@testable import MapQuestCore

/// The localization layer, and that every text of the app is translated: all text
/// in the app's sources goes through `tr`/`trn`, and every such text has a German
/// translation in `App/MapQuest/Resources/de.lproj/*.strings`.
final class LocalizationTests: XCTestCase {
    static let app = BraunschweigDataTests.root.deletingLastPathComponent()
    static let german = BraunschweigDataTests.root.appendingPathComponent("de.lproj")

    override func tearDown() {
        Localization.language = .en
        Localization.reset()
        super.tearDown()
    }

    // MARK: The layer

    func testTranslationAndPlaceholders() {
        Localization.register(["{0} of {1} sights": "{1}: {0} Sehenswürdigkeiten", "One region": "Eine Region",
                               "{0} regions": "{0} Regionen"], for: .de)
        XCTAssertEqual(tr("{0} of {1} sights", 3, 10), "3 of 10 sights")
        XCTAssertEqual(trn("One region", "{0} regions", 4), "4 regions")
        Localization.language = .de
        XCTAssertEqual(tr("{0} of {1} sights", 3, 10), "10: 3 Sehenswürdigkeiten")
        XCTAssertEqual(trn("One region", "{0} regions", 1), "Eine Region")
        XCTAssertEqual(trn("One region", "{0} regions", 2), "2 Regionen")
        XCTAssertEqual(tr("Not translated"), "Not translated", "falls back to English")
    }

    func testPreferredLanguage() {
        XCTAssertEqual(Language.preferred(from: ["de-DE", "en-US"]), .de)
        XCTAssertEqual(Language.preferred(from: ["fr-FR", "en-GB", "de"]), .en)
        XCTAssertEqual(Language.preferred(from: ["fr-FR"]), .en)
        XCTAssertEqual(Language.preferred(from: ["de_AT"]), .de)
    }

    func testBilingualNames() {
        let gate = BilingualName(german: "Brandenburger Tor", english: "Brandenburg Gate")
        XCTAssertEqual(gate.primary(.en), "Brandenburg Gate")
        XCTAssertEqual(gate.secondary(.en), "Brandenburger Tor")
        XCTAssertEqual(gate.primary(.de), "Brandenburger Tor")
        XCTAssertNil(gate.secondary(.de))
        XCTAssertEqual(gate.full(.en), "Brandenburg Gate (Brandenburger Tor)")
        let station = BilingualName(german: "Hauptbahnhof", english: "Central Station", germanFirst: true)
        XCTAssertEqual(station.primary(.en), "Hauptbahnhof")
        XCTAssertEqual(station.secondary(.en), "Central Station")
        let same = BilingualName(german: "Alexanderplatz", english: "Alexanderplatz")
        XCTAssertNil(same.secondary(.en))

        let sight = Sight(id: "t", name: "Brandenburger Tor", englishName: "Brandenburg Gate", category: .monument,
                          latitude: 52.5, longitude: 13.4)
        XCTAssertEqual(sight.name, "Brandenburg Gate")
        Localization.language = .de
        XCTAssertEqual(sight.name, "Brandenburger Tor")
        XCTAssertNil(sight.otherName)
    }

    func testHistoryInBothLanguages() throws {
        let context = try XCTUnwrap(BerlinHistory.context(in: 1789))
        XCTAssertEqual(context.era.name, "Kingdom of Prussia")
        XCTAssertEqual(context.ruler?.name, "Frederick William II")
        XCTAssertEqual(context.ruler?.otherName, "Friedrich Wilhelm II.")
        Localization.language = .de
        XCTAssertEqual(context.era.name, "Königreich Preußen")
        XCTAssertEqual(context.ruler?.name, "Friedrich Wilhelm II.")
        XCTAssertNil(context.ruler?.otherName)
        XCTAssertEqual(context.ruler?.title, "König von Preußen")
        XCTAssertEqual(BerlinHistory.context(in: 2010)?.ruler?.title, "Bundeskanzlerin")
        XCTAssertEqual(SightHistory(year: 1788, built: "1788–1791").builtPhrase, "Erbaut 1788–1791")
        XCTAssertEqual(AchievementGroup.architects.title, "Baumeister")
        for era in BerlinHistory.eras {
            Localization.language = .en
            let english = (era.name, era.summary)
            Localization.language = .de
            XCTAssertNotEqual(era.summary, english.1, era.id)
            XCTAssertFalse(era.name.isEmpty)
        }
    }

    func testStringsFileParser() throws {
        let entries = try StringsFile.entries("""
        /* A comment */
        "Done" = "Fertig";
        // Another
        "Say \\"hi\\"" = "Sag „hallo“\\nzweite Zeile";
        """)
        XCTAssertEqual(entries.map(\.key), ["Done", "Say \"hi\""])
        XCTAssertEqual(entries[1].value, "Sag „hallo“\nzweite Zeile")
        XCTAssertThrowsError(try StringsFile.entries("\"a\" = \"b\""))
        XCTAssertEqual(StringsFile.line("a \"b\"", "c\nd"), "\"a \\\"b\\\"\" = \"c\\nd\";")
    }

    // MARK: The app's text

    /// The German table: every `.strings` file of `de.lproj` but `InfoPlist.strings`.
    static func germanTable() throws -> [String: String] {
        var table: [String: String] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: german, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "strings" && $0.lastPathComponent != "InfoPlist.strings" }
        XCTAssertFalse(files.isEmpty, "no German tables")
        for file in files {
            let entries = try StringsFile.entries(String(contentsOf: file, encoding: .utf8))
            for (key, value) in entries {
                if let earlier = table[key], earlier != value {
                    XCTFail("\(file.lastPathComponent): “\(key)” translated twice, differently: “\(earlier)” and “\(value)”")
                }
                table[key] = value
            }
        }
        return table
    }

    func testEveryTextOfTheAppIsTranslated() throws {
        let table = try Self.germanTable()
        let texts = try AppSources.texts()
        var missing: [String] = []
        for text in texts.keys {
            guard let translation = table[text.key] else {
                missing.append("\(text.location): “\(text.key)”")
                continue
            }
            XCTAssertEqual(Self.placeholders(text.key), Self.placeholders(translation),
                           "\(text.location): placeholders of “\(text.key)” and “\(translation)”")
            XCTAssertFalse(translation.trimmingCharacters(in: .whitespaces).isEmpty, text.key)
        }
        XCTAssertTrue(missing.isEmpty, "no German translation:\n" + missing.sorted().joined(separator: "\n"))
        XCTAssertTrue(texts.problems.isEmpty, "\n" + texts.problems.joined(separator: "\n"))
        let used = Set(texts.keys.map(\.key))
        let unused = table.keys.filter { !used.contains($0) }.sorted()
        XCTAssertTrue(unused.isEmpty, "translations no text uses:\n" + unused.joined(separator: "\n"))
    }

    func testNoTextBypassesTranslation() throws {
        let texts = try AppSources.texts()
        XCTAssertTrue(texts.untranslated.isEmpty,
                      "text that does not go through tr()/trn() (mark proper names and other text that stays as it is with // not localized):\n"
                        + texts.untranslated.joined(separator: "\n"))
    }

    func testInfoPlistStrings() throws {
        let plist = try String(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Info.plist"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"<key>(NS\w+UsageDescription)</key>"#)
        let usage = Set(pattern.matches(in: plist, range: NSRange(plist.startIndex..., in: plist)).compactMap {
            Range($0.range(at: 1), in: plist).map { String(plist[$0]) }
        })
        XCTAssertFalse(usage.isEmpty)
        for language in ["en", "de"] {
            let url = BraunschweigDataTests.root.appendingPathComponent("\(language).lproj/InfoPlist.strings")
            let table = try StringsFile.parse(String(contentsOf: url, encoding: .utf8))
            XCTAssertEqual(Set(table.keys).intersection(usage), usage, "\(language): every usage description")
        }
    }

    static func placeholders(_ text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"\{\d+\}"#)
        return Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }
}

/// The text in the app's Swift sources: what goes through `tr`/`trn` (the keys),
/// and string literals that look like text but do not.
enum AppSources {
    struct Text {
        var key: String
        var location: String
    }

    struct Result {
        var keys: [Text] = []
        var problems: [String] = []
        var untranslated: [String] = []
    }

    static func files() throws -> [URL] {
        let root = LocalizationTests.app
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    static func texts() throws -> Result {
        var result = Result()
        for file in try files() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            let lines = source.components(separatedBy: "\n")
            let literals = SwiftLiterals.scan(source)
            let scalars = Array(source.unicodeScalars)
            var previousFirstOfTrn: SwiftLiterals.Literal?
            for literal in literals {
                let before = String(String.UnicodeScalarView(scalars[max(0, literal.start - 80)..<literal.start]))
                let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
                let line = literal.line <= lines.count ? lines[literal.line - 1] : ""
                let location = "\(name):\(literal.line)"
                var isKey = false
                var isFirstOfTrn = false
                if trimmed.hasSuffix("tr(") && !identifierContinues(trimmed, before: "tr(") {
                    isKey = true
                } else if trimmed.hasSuffix("trn(") && !identifierContinues(trimmed, before: "trn(") {
                    isKey = true
                    isFirstOfTrn = true
                } else if let first = previousFirstOfTrn,
                          String(String.UnicodeScalarView(scalars[first.end..<literal.start])).trimmingCharacters(in: .whitespacesAndNewlines) == "," {
                    isKey = true
                }
                previousFirstOfTrn = isFirstOfTrn ? literal : nil
                if isKey {
                    if literal.interpolated {
                        result.problems.append("\(location): interpolation in a key – use {0}, {1}: “\(literal.text)”")
                    } else {
                        result.keys.append(Text(key: literal.text, location: location))
                    }
                    continue
                }
                if line.contains("// not localized") || ignored(before: before) { continue }
                if looksLikeText(literal.text) {
                    result.untranslated.append("\(location): “\(literal.text)”")
                }
            }
            // tr/trn must be called with a literal (so its text can be found and translated).
            for (index, line) in lines.enumerated() where !line.contains("// not localized") {
                if line.range(of: #"(?<![\w.])trn?\(\s*[^"\s)]"#, options: .regularExpression) != nil {
                    result.problems.append("\(name):\(index + 1): tr()/trn() needs a string literal: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return result
    }

    private static func identifierContinues(_ text: String, before suffix: String) -> Bool {
        let head = text.dropLast(suffix.count)
        guard let last = head.last else { return false }
        return last.isLetter || last.isNumber || last == "_" || last == "."
    }

    /// Literals that are not text: symbols, keys, resources, logging.
    private static func ignored(before: String) -> Bool {
        let context = before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? before
        let markers = ["systemName:", "systemImage:", "forKey:", "forResource:", "withExtension:", "ofType:", "AppStorage(",
                       "SceneStorage(", "Notification.Name(", "URL(string:", "print(", "Logger(", "fatalError(", "assertionFailure(",
                       "precondition(", "Image(\"", "Color(\"", "subsystem:", "category:", "named:", "identifier:", "Identifier:",
                       "setLocalizedDateFormatFromTemplate(", "dateFormat =", "accessibilityIdentifier("]
        return markers.contains { context.hasSuffix($0) || context.hasSuffix($0 + " ") }
            || context.range(of: #"(systemName|systemImage|forKey|forResource|withExtension|named|accessibilityIdentifier)\s*:?\s*\(?$"#,
                             options: .regularExpression) != nil
    }

    /// Words with spaces, or a capitalised word ("Done", "Heatmap").
    static func looksLikeText(_ text: String) -> Bool {
        let plain = text.replacingOccurrences(of: "{}", with: "")
        if plain.range(of: #"^[A-Z][a-z]{2,}[.!?…]?$"#, options: .regularExpression) != nil { return true }
        guard plain.contains(" ") else { return false }
        return plain.range(of: #"[A-Za-zÄÖÜäöüß]{2,}"#, options: .regularExpression) != nil
            && plain.range(of: #"[a-zäöüß]{2,}"#, options: .regularExpression) != nil
    }
}

/// String literals in Swift source, with interpolations ("\(…)") as "{}".
enum SwiftLiterals {
    struct Literal {
        var line: Int
        /// Index of the opening quote and after the closing one (unicode scalars).
        var start: Int
        var end: Int
        var text: String
        var interpolated: Bool
    }

    static func scan(_ source: String) -> [Literal] {
        let c = Array(source.unicodeScalars)
        var i = 0
        var line = 1
        var found: [Literal] = []

        func at(_ offset: Int) -> Unicode.Scalar? { i + offset < c.count ? c[i + offset] : nil }

        func code(untilParen: Bool) {
            var depth = 0
            while i < c.count {
                let ch = c[i]
                if ch == "\n" { line += 1; i += 1; continue }
                if ch == "/", at(1) == "/" {
                    while i < c.count, c[i] != "\n" { i += 1 }
                    continue
                }
                if ch == "/", at(1) == "*" {
                    var nesting = 1
                    i += 2
                    while i < c.count, nesting > 0 {
                        if c[i] == "\n" { line += 1 }
                        if c[i] == "/", at(1) == "*" { nesting += 1; i += 2; continue }
                        if c[i] == "*", at(1) == "/" { nesting -= 1; i += 2; continue }
                        i += 1
                    }
                    continue
                }
                if ch == "#", at(1) == "\"" {
                    // A raw string: not text of the app (regular expressions); skipped.
                    i += 2
                    while i < c.count, !(c[i] == "\"" && at(1) == "#") {
                        if c[i] == "\n" { line += 1 }
                        i += 1
                    }
                    i += 2
                    continue
                }
                if ch == "\"" { string(); continue }
                if untilParen {
                    if ch == "(" { depth += 1 }
                    if ch == ")" {
                        if depth == 0 { i += 1; return }
                        depth -= 1
                    }
                }
                i += 1
            }
        }

        func string() {
            let start = i
            let startLine = line
            let multiline = at(1) == "\"" && at(2) == "\""
            i += multiline ? 3 : 1
            var text = String.UnicodeScalarView()
            var interpolated = false
            while i < c.count {
                let ch = c[i]
                if ch == "\\", let next = at(1) {
                    if next == "(" {
                        i += 2
                        interpolated = true
                        text.append(contentsOf: "{}".unicodeScalars)
                        code(untilParen: true)
                        continue
                    }
                    switch next {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    default: text.append(next)
                    }
                    i += 2
                    continue
                }
                if multiline {
                    if ch == "\"", at(1) == "\"", at(2) == "\"" { i += 3; break }
                } else if ch == "\"" {
                    i += 1
                    break
                } else if ch == "\n" {
                    break
                }
                if ch == "\n" { line += 1 }
                text.append(ch)
                i += 1
            }
            found.append(Literal(line: startLine, start: start, end: i, text: String(text), interpolated: interpolated))
        }

        code(untilParen: false)
        // Literals inside interpolations are found first; in source order:
        return found.sorted { $0.start < $1.start }
    }
}

