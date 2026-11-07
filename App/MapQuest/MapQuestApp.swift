import SwiftUI

@main
struct MapQuestApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.tracker)
        }
    }
}

/// Shows the permission onboarding until the user has answered the location prompt.
struct RootView: View {
    @EnvironmentObject private var tracker: LocationTracker
    @AppStorage("RootView.skippedOnboarding") private var skippedOnboarding = false

    var body: some View {
        if tracker.needsPermissionPrompt && !skippedOnboarding {
            PermissionView(onSkip: { skippedOnboarding = true })
        } else {
            ContentView()
        }
    }
}
