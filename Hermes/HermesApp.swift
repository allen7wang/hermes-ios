import SwiftUI

@main
struct HermesApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
