import SwiftUI

struct WorkspaceHomeView: View {
    @EnvironmentObject private var model: AppModel
    let onOpenChat: (LocalMessageTarget?) -> Void
    @State private var error: String?
    @State private var route: WorkspaceDestination?
    @State private var showingSettings = false

    var body: some View {
        let snapshot = try? model.workspaceSnapshot()
        let drafts = snapshot?.draftItems() ?? []
        let recent = model.conversations.filter { !$0.isArchived }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Label("HERMES / WORKSPACE", systemImage: "circle.hexagongrid.fill")
                        .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(HermesTheme.accent)
                    Text("从上次停下的地方，继续。").font(.title2.bold())
                    Text(model.activeProfileName + " · 本机工作区").font(.subheadline).foregroundStyle(HermesTheme.muted)
                    if model.needsRecovery || !model.settings.isConfigured {
                        Button { showingSettings = true } label: {
                            Label(model.needsRecovery ? "本机数据需要恢复" : "配置 Hermes 服务器", systemImage: "exclamationmark.circle")
                                .font(.subheadline)
                        }.accessibilityIdentifier("home-connection-status")
                    }
                    Button {
                        do { try model.startWorkspaceConversation(profileID: model.activeProfileID); onOpenChat(nil) }
                        catch { self.error = error.localizedDescription }
                    } label: {
                        HStack { Label("开始新对话", systemImage: "square.and.pencil"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(.subheadline.weight(.semibold)).padding(14)
                            .foregroundStyle(HermesTheme.background)
                            .background(HermesTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(model.isSending || model.needsRecovery).accessibilityIdentifier("home-new-chat")
                    if model.isSending { Text("回复正在生成，完成或停止后可切换对话。").font(.caption).foregroundStyle(HermesTheme.muted) }
                }.padding(.vertical, 8)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section {
                NavigationLink { WorkspaceSearchView(onOpenChat: onOpenChat) } label: {
                    action("统一检索", subtitle: "对话、消息、项目、资料与草稿", icon: "magnifyingglass")
                }.disabled(model.needsRecovery).accessibilityIdentifier("home-search")
                NavigationLink {
                    HistoryView(embedded: true) { onOpenChat(nil) }
                } label: {
                    action("全部对话", subtitle: "筛选、批量整理、归档与回收站", icon: "bubble.left.and.bubble.right")
                }.accessibilityIdentifier("home-all-conversations")
            }.listRowBackground(HermesTheme.surface)
            Section {
                if drafts.isEmpty {
                    Text(model.needsRecovery ? "恢复本机数据后可查看草稿。" : "暂无进行中的文字草稿。未发送的内容会保留在对应对话。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                }
                ForEach(Array(drafts.prefix(3))) { item in resultButton(item) }
                NavigationLink { WorkspaceDraftListView(onOpenChat: onOpenChat) } label: {
                    Label("全部草稿", systemImage: "tray.full").font(.subheadline)
                }.disabled(model.needsRecovery).accessibilityIdentifier("home-all-drafts")
            } header: { Text("继续草稿 · \(drafts.count)") }
            footer: { Text("只列进行中的本机文字草稿；新对话草稿优先，其余按对话更新时间排列。") }
                .listRowBackground(HermesTheme.surface)
            Section("最近对话") {
                if recent.isEmpty { Text("从一段新对话开始。").foregroundStyle(HermesTheme.muted) }
                ForEach(Array(recent.prefix(5))) { conversation in
                    Button { open(.conversation(conversation.id)) } label: {
                        WorkspaceConversationRow(conversation: conversation, projectName: model.project(for: conversation)?.name)
                    }.buttonStyle(.plain).disabled(model.isSending || model.needsRecovery)
                        .accessibilityIdentifier("home-recent-\(conversation.id)")
                }
            }.listRowBackground(HermesTheme.surface)
            Section("最近项目") {
                if model.projects.isEmpty { Text("在“项目”中收纳长期工作、共同指令和资料。").font(.subheadline).foregroundStyle(HermesTheme.muted) }
                ForEach(Array(model.projects.prefix(3))) { project in
                    Button { open(.project(project.id)) } label: {
                        action(project.name, subtitle: "\(project.documents.count) 篇资料" + (project.summary.isEmpty ? "" : " · " + project.summary), icon: "folder")
                    }.buttonStyle(.plain).disabled(model.isSending || model.needsRecovery)
                }
            }.listRowBackground(HermesTheme.surface)
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
        .navigationTitle("工作台").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $route) { destination in
            WorkspaceDetailDestination(destination: destination, profileID: model.activeProfileID, onOpenChat: onOpenChat)
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .alert("暂时无法打开", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .onChange(of: model.activeProfileID) { _, _ in route = nil; error = nil }
    }

    private func action(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(HermesTheme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(subtitle).font(.caption).foregroundStyle(HermesTheme.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6)
    }
    private func resultButton(_ item: WorkspaceSearchResult) -> some View {
        Button { open(item.destination) } label: { WorkspaceSearchResultRow(item: item) }
            .buttonStyle(.plain).disabled(model.isSending || model.needsRecovery)
    }
    private func open(_ destination: WorkspaceDestination) {
        do {
            try model.openWorkspaceDestination(destination, profileID: model.activeProfileID)
            if case .project = destination { route = destination }
            else { onOpenChat(nil) }
        } catch { self.error = error.localizedDescription }
    }
}

struct WorkspaceDetailDestination: View {
    let destination: WorkspaceDestination
    let profileID: UUID
    let onOpenChat: (LocalMessageTarget?) -> Void
    var body: some View {
        switch destination {
        case .project(let id): ProjectDetailView(projectID: id, profileID: profileID) { onOpenChat(nil) }
        case .document(let project, let document): ProjectDocumentDetailView(projectID: project, profileID: profileID, documentID: document)
        default: ContentUnavailableView("目标已改变", systemImage: "arrow.clockwise", description: Text("请返回工作台重新打开。"))
        }
    }
}

struct WorkspaceSearchResultRow: View {
    let item: WorkspaceSearchResult
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.icon).foregroundStyle(HermesTheme.accent).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                Text(item.subtitle + (item.archived ? " · 已归档" : "")).font(.caption).foregroundStyle(HermesTheme.accent).lineLimit(2)
                Text(item.excerpt).font(.caption).foregroundStyle(HermesTheme.muted).lineLimit(3)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(HermesTheme.muted).padding(.top, 4)
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
}
