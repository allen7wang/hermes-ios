import SwiftUI

enum WorkspaceNavigationRoute: Hashable {
    case search, conversations, drafts
    case detail(WorkspaceDestination, profileID: UUID)
    case chat(LocalMessageTarget?)
}

struct AppShell: View {
    @EnvironmentObject private var model: AppModel
    private enum Section: Hashable { case conversations, projects, server, library, settings }
    @State private var section: Section = .conversations
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
            }.tabItem { Label("工作台", systemImage: "square.grid.2x2") }.tag(Section.conversations)
            ProjectWorkspaceView(embedded: true) {
                section = .conversations
                openChat(nil)
            }.tabItem { Label("项目", systemImage: "folder") }.tag(Section.projects)
            RemoteWorkspaceView(embedded: true)
                .tabItem { Label("服务端", systemImage: "server.rack") }.tag(Section.server)
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
                .tabItem { Label("消息库", systemImage: "books.vertical") }.tag(Section.library)
            SettingsView(embedded: true)
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(Section.settings)
        }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
        .alert("暂时无法打开原文", isPresented: Binding(get: { navigationError != nil }, set: { if !$0 { navigationError = nil } })) {
            Button("知道了", role: .cancel) { navigationError = nil }
        } message: { Text(navigationError ?? "") }
        .onChange(of: model.activeProfileID) { _, _ in
            workspacePath = []
            navigationError = nil
        }
    }

    private func openChat(_ target: LocalMessageTarget?) {
        workspacePath.append(.chat(target))
    }

    private func openDetail(_ destination: WorkspaceDestination, profileID: UUID) {
        workspacePath.append(.detail(destination, profileID: profileID))
    }
}
