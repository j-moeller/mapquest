import Foundation
import MapQuestCore
import SwiftUI

/// The language chosen in the menu: the system's, English or German.
enum LanguageChoice: String, CaseIterable, Identifiable {
    case system, en, de

    var id: String { rawValue }

    var language: Language? { Language(rawValue: rawValue) }
}

/// The app's language: chosen in the menu (default: the system's), applied at once
/// to all of the app's text and data, and – through `AppleLanguages` – to the
/// system's own dialogs (camera, permissions) from the next launch.
@MainActor
final class LanguageSettings: ObservableObject {
    static let choiceKey = "appLanguage"
    private static let appleLanguages = "AppleLanguages"

    @Published var choice: LanguageChoice {
        didSet {
            guard choice != oldValue else { return }
            UserDefaults.standard.set(choice.rawValue, forKey: Self.choiceKey)
            if let language = choice.language {
                UserDefaults.standard.set([language.rawValue], forKey: Self.appleLanguages)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.appleLanguages)
            }
            apply()
        }
    }

    /// The language the app's text is in now.
    @Published private(set) var language: Language

    init() {
        Self.loadTranslations()
        var choice = LanguageChoice(rawValue: UserDefaults.standard.string(forKey: Self.choiceKey) ?? "") ?? .system
        // A language set for the app in the system's Settings (it writes AppleLanguages) wins over an older choice here.
        if let chosen = choice.language, let perApp = Self.perAppLanguages(), Language.preferred(from: perApp) != chosen {
            choice = .system
            UserDefaults.standard.set(choice.rawValue, forKey: Self.choiceKey)
        }
        self.choice = choice
        language = choice.language ?? Self.systemLanguage
        Localization.formatRegion = Locale.current.region?.identifier
        Localization.language = language
    }

    /// The system's language for the app: its own setting in the system's Settings, else the device's.
    /// (Read while no language is chosen here: a choice here is written to the same setting.)
    static var systemLanguage: Language {
        Language.preferred(from: UserDefaults.standard.stringArray(forKey: appleLanguages) ?? Locale.preferredLanguages)
    }

    /// The device's language (what "System" would mean while a language is chosen here).
    static var deviceLanguage: Language {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[appleLanguages] as? [String]
        return Language.preferred(from: global ?? Locale.preferredLanguages)
    }

    private func apply() {
        let language = choice.language ?? Self.systemLanguage
        Localization.language = language
        if language != self.language { self.language = language }
    }

    /// AppleLanguages set for this app only (by the system's Settings or by this menu).
    private static func perAppLanguages() -> [String]? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return UserDefaults.standard.persistentDomain(forName: id)?[appleLanguages] as? [String]
    }

    /// The German tables (`de.lproj/*.strings`, compiled into the app).
    private static func loadTranslations() {
        for url in Bundle.main.urls(forResourcesWithExtension: "strings", subdirectory: nil, localization: "de") ?? []
        where url.lastPathComponent != "InfoPlist.strings" {
            if let table = NSDictionary(contentsOf: url) as? [String: String] {
                Localization.register(table, for: .de)
            }
        }
    }

    /// "System (English)", "English", "Deutsch".
    func title(of choice: LanguageChoice) -> String {
        switch choice {
        case .system: return tr("System ({0})", (self.choice == .system ? Self.systemLanguage : Self.deviceLanguage).autonym)
        case .en, .de: return choice.language?.autonym ?? ""
        }
    }
}
