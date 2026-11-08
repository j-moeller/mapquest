import SwiftUI

@main
struct MapQuestApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.tracker)
        }
        .onChange(of: scenePhase) { _, phase in
            // Buffered track fixes are written before the app may be suspended.
            if phase != .active {
                Task { await model.flushTrack() }
            }
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
