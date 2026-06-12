import SwiftUI

@main
struct RecordAppApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }
    }
}
