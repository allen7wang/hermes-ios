import SwiftUI

struct AppShell: View {
    @EnvironmentObject private var model: AppModel
    private enum Section: Hashable { case conversations, server, library, settings }
    @State private var section: Section = .conversations
    @State private var showingChat = false
    @State private var libraryTarget: LocalMessageTarget?
    @State private var navigationError: String?

    var body: some View {
        TabView(selection: $section) {
            NavigationStack {
                HistoryView(embedded: true) { libraryTarget = nil; showingChat = true }
                    .navigationDestination(isPresented: $showingChat) {
                        ChatView(initialTarget: libraryTarget)
                            .toolbar(.hidden, for: .navigationBar)
                            .toolbar(.hidden, for: .tabBar)
                    }
            }.tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }.tag(Section.conversations)
            RemoteWorkspaceView(embedded: true)
                .tabItem { Label("服务端", systemImage: "server.rack") }.tag(Section.server)
            MessageLibraryView(embedded: true) { target in
                do {
                    try model.openMessage(target)
                    libraryTarget = target
                    section = .conversations
                    showingChat = true
                } catch { navigationError = error.localizedDescription }
            }.id(model.activeProfileID)
                .tabItem { Label("消息库", systemImage: "books.vertical") }.tag(Section.library)
            SettingsView(embedded: true)
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(Section.settings)
        }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
        .alert("暂时无法打开原文", isPresented: Binding(get: { navigationError != nil }, set: { if !$0 { navigationError = nil } })) {
            Button("知道了", role: .cancel) { navigationError = nil }
        } message: { Text(navigationError ?? "") }
        .onChange(of: model.activeProfileID) { _, _ in showingChat = false; libraryTarget = nil }
    }
}
