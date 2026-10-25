import SwiftUI

struct AppShell: View {
    @EnvironmentObject private var model: AppModel
    private enum Section: Hashable { case conversations, projects, server, library, settings }
    @State private var section: Section = .conversations
    @State private var showingChat = false
    @State private var libraryTarget: LocalMessageTarget?
    @State private var navigationError: String?

    var body: some View {
        TabView(selection: $section) {
            NavigationStack {
                WorkspaceHomeView { target in libraryTarget = target; showingChat = true }
                    .navigationDestination(isPresented: $showingChat) {
                        ChatView(initialTarget: libraryTarget)
                            .toolbar(.hidden, for: .navigationBar)
                            .toolbar(.hidden, for: .tabBar)
                    }
            }.id(model.activeProfileID).tabItem { Label("工作台", systemImage: "square.grid.2x2") }.tag(Section.conversations)
            ProjectWorkspaceView(embedded: true) {
                libraryTarget = nil
                section = .conversations
                showingChat = true
            }.tabItem { Label("项目", systemImage: "folder") }.tag(Section.projects)
            RemoteWorkspaceView(embedded: true)
                .tabItem { Label("服务端", systemImage: "server.rack") }.tag(Section.server)
            MessageLibraryView(embedded: true, onShowDraft: {
                libraryTarget = nil
                section = .conversations
                showingChat = true
            }) { target in
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
