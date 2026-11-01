import SwiftUI

@main
struct HermesApp: App {
    #if DEBUG
    @StateObject private var model = NativeAcceptanceSupport.makeModel()
    #else
    @StateObject private var model = AppModel()
    #endif

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
