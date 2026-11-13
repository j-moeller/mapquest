import MapQuestCore
import SwiftUI

@main
struct MapQuestApp: App {
    // First: the language is set before the models make any text.
    @StateObject private var languages = LanguageSettings()
    @StateObject private var model = AppModel()
    @StateObject private var captures = CaptureModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.tracker)
                .environmentObject(captures)
                .environmentObject(languages)
                // Dates, numbers and system controls in the app's language.
                .environment(\.locale, Localization.locale)
        }
        // Also at launch: the system can relaunch the app in the background (significant location change).
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Buffered track fixes are written before the app may be suspended.
            if phase != .active {
                Task { await model.flushTrack() }
            }
            // In the background the maps rest and the tracker may save power.
            if phase != .inactive {
                model.setInBackground(phase == .background)
            }
        }
    }
}

/// Shows the permission onboarding until the user has answered the location prompt.
struct RootView: View {
    @EnvironmentObject private var tracker: LocationTracker
    @EnvironmentObject private var languages: LanguageSettings
    @AppStorage("RootView.skippedOnboarding") private var skippedOnboarding = false

    var body: some View {
        if tracker.needsPermissionPrompt && !skippedOnboarding {
            PermissionView(onSkip: { skippedOnboarding = true })
                // Built again in another language.
                .id(languages.language)
        } else {
            ContentView()
        }
    }
}
