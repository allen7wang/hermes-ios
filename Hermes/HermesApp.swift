import SwiftUI

@main
struct HermesApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
