import SwiftUI

/// The debug settings as a panel over the map: a sheet with three heights, the
/// map above it stays visible and interactive (pan, zoom, long-press to place
/// test positions) while the sliders are tuned.
struct DebugPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            DebugSettingsView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.showsDebugPanel = false }
                    }
                }
        }
    }
}

extension View {
    /// Presents the debug panel without hiding the map: small and medium heights let
    /// touches through to the map; the large height covers it.
    func debugPanel(isPresented: Binding<Bool>, detent: Binding<PresentationDetent>) -> some View {
        sheet(isPresented: isPresented) {
            DebugPanel()
                .presentationDetents([DebugPanelDetent.small, .medium, .large], selection: detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
        }
    }
}

enum DebugPanelDetent {
    /// The fog sliders and the map above them.
    static let small = PresentationDetent.height(300)
}
