import SwiftUI

@main
struct DuoBrowserApp: App {
    @State private var store = TabStore.restored() ?? TabStore.withSampleTabs()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environment(store)
        }
        // Save on the way out, which also covers the app being closed from the app switcher:
        // it's backgrounded first.
        .onChange(of: scenePhase) {
            if scenePhase != .active { store.save() }
        }
    }
}
