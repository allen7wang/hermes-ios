import SwiftUI

enum WorkspaceNavigationRoute: Hashable {
    case search, conversations, drafts
    case detail(WorkspaceDestination, profileID: UUID)
    case chat(LocalMessageTarget?)
}

private enum AppSection: Hashable { case conversations, projects, server, library, settings }

struct AppShell: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: AppSection = .conversations

    var body: some View {
        ConnectionWorkspaceTabs(section: $section)
            .id(model.activeProfileID)
    }
}

// Scope the entire tab controller and its navigation state to one connection.
// Replacing an individual offscreen navigation stack can retain a stale UIKit bar.
private struct ConnectionWorkspaceTabs: View {
    @EnvironmentObject private var model: AppModel
    @Binding var section: AppSection
    @State private var workspacePath: [WorkspaceNavigationRoute] = []
    @State private var navigationError: String?

    var body: some View {
        TabView(selection: $section) {
            NavigationStack(path: $workspacePath) {
                WorkspaceHomeView(onOpenChat: openChat, onOpenDetail: openDetail)
                    .navigationDestination(for: WorkspaceNavigationRoute.self) { route in
                        switch route {
                        case .search:
                            WorkspaceSearchView(onOpenChat: openChat, onOpenDetail: openDetail)
                        case .conversations:
                            HistoryView(embedded: true) { openChat(nil) }
                        case .drafts:
                            WorkspaceDraftListView(onOpenChat: openChat)
                        case .detail(let destination, let profileID):
                            WorkspaceDetailDestination(destination: destination, profileID: profileID, onOpenChat: openChat)
                        case .chat(let target):
                            ChatView(initialTarget: target)
                                .toolbar(.hidden, for: .navigationBar)
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
            }.tabItem { Label("工作台", systemImage: "square.grid.2x2") }.tag(AppSection.conversations)
            ProjectWorkspaceView(embedded: true) {
                section = .conversations
                openChat(nil)
            }.tabItem { Label("项目", systemImage: "folder") }.tag(AppSection.projects)
            RemoteWorkspaceView(embedded: true)
                .tabItem { Label("服务端", systemImage: "server.rack") }.tag(AppSection.server)
            MessageLibraryView(embedded: true, onShowDraft: {
                section = .conversations
                openChat(nil)
            }) { target in
                do {
                    try model.openMessage(target)
                    section = .conversations
                    openChat(target)
                } catch { navigationError = error.localizedDescription }
            }
                .tabItem { Label("消息库", systemImage: "books.vertical") }.tag(AppSection.library)
            SettingsView(embedded: true)
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(AppSection.settings)
        }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
        .alert("暂时无法打开原文", isPresented: Binding(get: { navigationError != nil }, set: { if !$0 { navigationError = nil } })) {
            Button("知道了", role: .cancel) { navigationError = nil }
        } message: { Text(navigationError ?? "") }
    }

    private func openChat(_ target: LocalMessageTarget?) {
        workspacePath.append(.chat(target))
    }

    private func openDetail(_ destination: WorkspaceDestination, profileID: UUID) {
        workspacePath.append(.detail(destination, profileID: profileID))
    }
}
