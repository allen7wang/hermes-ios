import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var onOpen: (() -> Void)? = nil
    @State private var query = ""
    @State private var scope: ConversationScope = .active
    @State private var sort: ConversationSort = .recent
    @State private var tag: String?
    @State private var project: ProjectFilter = .all
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var deleting = Set<UUID>()
    @State private var confirmingPermanentDeletion = false
    @State private var trashPreview: Conversation?
    @State private var recentlyTrashed = Set<UUID>()
    @State private var settingsTarget: ConversationSettingsTarget?
    @State private var document: ConversationDocument?
    @State private var exporting = false
    @State private var showingConnections = false
    @State private var showingProjects = false
    @State private var moveTarget: ProjectMoveTarget?
    @State private var exportName = "Hermes-对话"

    init(embedded: Bool = false, initialProject: ProjectFilter = .all, onOpen: (() -> Void)? = nil) {
        self.embedded = embedded
        self.onOpen = onOpen
        _project = State(initialValue: initialProject)
    }

    private var visible: [Conversation] {
        ConversationWorkbench.filtered(records, scope: scope, query: query, tag: tag, sort: sort, project: project)
    }
    private var records: [Conversation] { scope == .trash ? model.trashedConversations : model.conversations }
    private var projectConversations: [Conversation] { model.conversations.filter(matchesProject) }
    private var projectTrash: [Conversation] { model.trashedConversations.filter(matchesProject) }
    private var tags: [String] { Array(Set(records.flatMap { $0.workspaceState.tags })).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private var visibleIDs: Set<UUID> { Set(visible.map(\.id)) }
    private var undoIDs: Set<UUID> { recentlyTrashed.intersection(Set(model.trashedConversations.map(\.id))) }

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
        .sheet(isPresented: $showingConnections) { SettingsView() }
        .sheet(isPresented: $showingProjects) {
            ProjectWorkspaceView {
                showingProjects = false
                openChat()
            }
        }
        .sheet(item: $moveTarget) { target in
            ProjectAssignmentView(target: target) { selected = []; moveTarget = nil }
        }
        .sheet(item: $trashPreview) { record in TrashConversationView(conversationID: record.id) }
        .sheet(item: $settingsTarget) { target in
            ConversationSettingsView(conversationID: target.conversationID, profileID: target.profileID, draftKey: target.draftKey)
        }
        .confirmationDialog("彻底删除 \(deleting.count) 段对话？", isPresented: $confirmingPermanentDeletion, titleVisibility: .visible) {
            Button("彻底删除对话与对应草稿", role: .destructive) {
                let ids = deleting
                perform { try model.permanentlyDeleteConversations(ids) }
                selected.subtract(ids)
                deleting = []
            }
            Button("取消", role: .cancel) { deleting = [] }
        } message: { Text("这一步无法从回收站撤销。收藏和对应草稿将删除；其他对话（包括回收站）仍引用的图片会保留。建议先导出备份。") }
        .fileExporter(isPresented: $exporting, document: document, contentType: ConversationDocument.markdownType, defaultFilename: exportName) { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .onChange(of: visibleIDs) { _, ids in selected.formIntersection(ids) }
        .onChange(of: model.activeProfileID) { _, _ in query = ""; tag = nil; project = .all; scope = .active; selected = []; selecting = false; recentlyTrashed = []; moveTarget = nil; showingProjects = false }
        .onChange(of: tags) { _, values in if let tag, !values.contains(tag) { self.tag = nil } }
        .onChange(of: model.projects) { _, values in
            if case .project(let id) = project, !values.contains(where: { $0.id == id }) { project = .all }
        }
    }

    private var content: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 9) {
                        Image(systemName: "circle.hexagongrid.fill").foregroundStyle(HermesTheme.accent)
                        Text("HERMES / WORKSPACE").font(.caption.weight(.semibold)).tracking(2)
                    }.foregroundStyle(HermesTheme.muted)
                    Text("把想法，继续下去。").font(.title2.bold())
                    if !model.settings.isConfigured || model.needsRecovery {
                        Button { showingConnections = true } label: {
                            HStack {
                                Image(systemName: model.needsRecovery ? "externaldrive.badge.exclamationmark" : "server.rack")
                                Text(model.needsRecovery ? "本机数据需要恢复 · 打开备份与恢复" : "先配置服务器，连接你自己的 Hermes")
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                            }.font(.caption).foregroundStyle(HermesTheme.accent)
                        }.buttonStyle(.plain)
                    }
                    HStack(spacing: 10) {
                        metric("进行中", count: projectConversations.filter { !$0.isArchived }.count, icon: "bubble.left.and.bubble.right", target: .active)
                        metric("已置顶", count: projectConversations.filter { !$0.isArchived && $0.isPinned }.count, icon: "pin", target: .pinned)
                        metric("已归档", count: projectConversations.filter(\.isArchived).count, icon: "archivebox", target: .archived)
                        metric("回收站", count: projectTrash.count, icon: "trash", target: .trash)
                    }
                    Button(action: newConversation) {
                        HStack { Label("开始新对话", systemImage: "square.and.pencil"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(.subheadline.weight(.semibold)).padding(14)
                            .foregroundStyle(HermesTheme.background).background(HermesTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(model.isSending || model.needsRecovery).accessibilityIdentifier("workbench-new-chat")
                    if case .project = project {
                        Text("将在「\(projectLabel)」创建并保存一段独立对话，打开后手动发送。")
                            .font(.caption).foregroundStyle(HermesTheme.muted)
                    }
                }.padding(.vertical, 8)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section {
                HStack(spacing: 12) {
                    Menu {
                        Picker("项目范围", selection: $project) {
                            Text("全部项目").tag(ProjectFilter.all)
                            Text("未分配").tag(ProjectFilter.unassigned)
                            ForEach(model.projects) { value in Text(value.name).tag(ProjectFilter.project(value.id)) }
                        }
                    } label: {
                        HStack(spacing: 6) { Image(systemName: "folder"); Text(projectLabel).lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }
                            .font(.subheadline.weight(.medium)).foregroundStyle(HermesTheme.accent)
                    }.accessibilityLabel("筛选项目，\(projectLabel)").accessibilityIdentifier("workbench-project-filter")
                    Spacer(minLength: 8)
                    Button("管理项目") { showingProjects = true }.font(.caption.weight(.medium))
                        .accessibilityIdentifier("workbench-manage-projects")
                }.padding(.vertical, 4).listRowBackground(Color.clear)
                Picker("对话范围", selection: $scope) { ForEach(ConversationScope.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            tagButton(nil)
                            ForEach(tags, id: \.self) { tagButton($0) }
                        }
                    }.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0)).listRowBackground(Color.clear)
                }
                if scope == .trash {
                    Text("记录保留至你手动彻底删除。恢复会保留原来的标签、归档状态、收藏、草稿和附件；JSON 备份也包含回收站。")
                        .font(.caption).foregroundStyle(HermesTheme.muted).listRowBackground(Color.clear)
                }
            }.listRowSeparator(.hidden)
            Section {
                if visible.isEmpty {
                    ContentUnavailableView(query.isEmpty && tag == nil ? (scope == .trash ? "回收站是空的" : scope == .archived ? "归档区还是空的" : "留一个位置给新想法") : "没有匹配的对话",
                        systemImage: scope == .trash ? "trash" : scope == .archived ? "archivebox" : "bubble.left.and.bubble.right",
                        description: Text(query.isEmpty && tag == nil ? (scope == .trash ? "移入回收站的对话可在这里查看和恢复。" : "发送消息后会自动保存。长按对话可整理标签、置顶或归档。") : "试试其他关键词、标签或范围。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(visible) { conversation in
                    Button {
                        if selecting {
                            if !selected.insert(conversation.id).inserted { selected.remove(conversation.id) }
                        } else if conversation.isTrashed {
                            trashPreview = conversation
                        } else {
                            if model.select(conversation.id) { openChat() }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if selecting {
                                Image(systemName: selected.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(conversation.id) ? HermesTheme.accent : HermesTheme.muted)
                            }
                            WorkspaceConversationRow(conversation: conversation, projectName: model.project(for: conversation)?.name)
                        }
                    }
                    .buttonStyle(.plain).disabled(model.isSending)
                    .accessibilityIdentifier("workbench-row-\(conversation.id)")
                    .listRowBackground(HermesTheme.surface)
                    .contextMenu { recordActions(conversation) }
                    .swipeActions {
                        Button(conversation.isTrashed ? "恢复" : conversation.isArchived ? "取消归档" : "归档", systemImage: "archivebox") {
                            perform {
                                if conversation.isTrashed { try model.restoreConversations([conversation.id]) }
                                else { try model.setArchived([conversation.id], archived: !conversation.isArchived) }
                            }
                        }.tint(HermesTheme.muted)
                    }
                }
            } header: {
                HStack { Text("\(visible.count) 段对话"); Spacer(); Text(selecting ? "已选 \(selected.count) 段" : sort.title) }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
        .searchable(text: $query, prompt: "搜索标题、消息或标签")
        .navigationTitle(model.activeProfileName).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("排序", selection: $sort) { ForEach(ConversationSort.allCases) { Text($0.title).tag($0) } }
                    Button(selecting ? "完成整理" : "批量整理", systemImage: "checklist") { selecting.toggle(); selected = [] }
                    if selecting { Button("选择当前结果", systemImage: "checkmark.circle") { selected = visibleIDs } }
                    Button("新对话默认设置", systemImage: "slider.horizontal.3") { if model.newConversation() { showSettings() } }
                } label: { Image(systemName: "slider.horizontal.3") }
                .disabled(model.isSending).accessibilityLabel("工作台选项")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                HStack(spacing: 20) {
                    Button(scope == .trash ? "恢复" : scope == .archived ? "取消归档" : "归档", systemImage: "archivebox") {
                        perform {
                            if scope == .trash { try model.restoreConversations(selected) }
                            else { try model.setArchived(selected, archived: scope != .archived) }
                        }
                        selected = []
                    }
                    Button("导出", systemImage: "square.and.arrow.up") { export(visible.filter { selected.contains($0.id) }) }
                    if scope != .trash {
                        Button("项目", systemImage: "folder") { requestMove(selected) }
                            .accessibilityLabel("将所选对话移动到项目")
                    }
                    Spacer()
                    Button(scope == .trash ? "彻底删除" : "移到回收站", systemImage: "trash", role: .destructive) {
                        if scope == .trash { requestPermanentDeletion(selected) }
                        else { moveToTrash(selected) }
                    }
                }.font(.subheadline).padding(16).background(HermesTheme.surface)
                    .disabled(selected.isEmpty || model.isSending || model.needsRecovery)
            } else if !undoIDs.isEmpty {
                HStack {
                    Label("已移到回收站", systemImage: "trash")
                    Spacer()
                    Button("撤销") {
                        perform { try model.restoreConversations(undoIDs); recentlyTrashed = [] }
                    }.disabled(model.isSending || model.needsRecovery)
                }.font(.subheadline).padding(16).background(HermesTheme.surface)
            }
        }
        .alert("操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func metric(_ title: String, count: Int, icon: String, target: ConversationScope) -> some View {
        Button { scope = target } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).foregroundStyle(HermesTheme.accent)
                Text("\(count)").font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
                Text(title).font(.caption).foregroundStyle(HermesTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(scope == target ? HermesTheme.raised : HermesTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel("\(title)，\(count) 段对话")
    }

    private func tagButton(_ value: String?) -> some View {
        Button { tag = value } label: {
            Text(value.map { "# " + $0 } ?? "全部标签").font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
                .background(tag == value ? HermesTheme.accent.opacity(0.18) : HermesTheme.surface, in: Capsule())
                .foregroundStyle(tag == value ? HermesTheme.accent : HermesTheme.muted)
        }.buttonStyle(.plain)
    }
    private var projectLabel: String {
        switch project {
        case .all: "全部项目"
        case .unassigned: "未分配"
        case .project(let id): model.projects.first { $0.id == id }?.name ?? "全部项目"
        }
    }
    private func matchesProject(_ conversation: Conversation) -> Bool {
        switch project {
        case .all: true
        case .unassigned: conversation.projectID == nil
        case .project(let id): conversation.projectID == id
        }
    }
    private func newConversation() {
        do {
            if case .project(let id) = project { _ = try model.startProjectConversation(id, profileID: model.activeProfileID) }
            else { guard model.newConversation() else { return } }
            openChat()
        } catch { model.errorMessage = error.localizedDescription }
    }
    @ViewBuilder private func recordActions(_ conversation: Conversation) -> some View {
        if conversation.isTrashed {
            Button("查看原消息", systemImage: "eye") { trashPreview = conversation }
            Button("恢复对话", systemImage: "arrow.uturn.backward") { perform { try model.restoreConversations([conversation.id]) } }
            Button("彻底删除", systemImage: "trash", role: .destructive) { requestPermanentDeletion([conversation.id]) }
        } else {
            Button("对话设置与标签", systemImage: "tag") { edit(conversation) }
            Button("移动到项目", systemImage: "folder") { requestMove([conversation.id]) }
            Button(conversation.isPinned ? "取消置顶" : "置顶", systemImage: "pin") { model.togglePin(conversation.id) }
            Button(conversation.isArchived ? "取消归档" : "归档", systemImage: "archivebox") {
                perform { try model.setArchived([conversation.id], archived: !conversation.isArchived) }
            }
            Button("移到回收站", systemImage: "trash", role: .destructive) { moveToTrash([conversation.id]) }
        }
        Button("导出 Markdown", systemImage: "square.and.arrow.up") { export([conversation]) }
    }
    private func requestPermanentDeletion(_ ids: Set<UUID>) { deleting = ids; confirmingPermanentDeletion = true }
    private func requestMove(_ ids: Set<UUID>) { moveTarget = ProjectMoveTarget(conversationIDs: ids, profileID: model.activeProfileID) }
    private func moveToTrash(_ ids: Set<UUID>) {
        perform { try model.deleteConversations(ids); recentlyTrashed = ids; selected.subtract(ids) }
    }
    private func openChat() { if let onOpen { onOpen() } else { dismiss() } }
    private func edit(_ conversation: Conversation) { if model.select(conversation.id) { showSettings() } }
    private func showSettings() { settingsTarget = ConversationSettingsTarget(conversationID: model.selectedID, profileID: model.activeProfileID, draftKey: model.draftKey) }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { model.errorMessage = error.localizedDescription } }
    private func export(_ conversations: [Conversation]) {
        guard !conversations.isEmpty else { return }
        document = ConversationDocument(text: ConversationWorkbench.markdown(conversations))
        exportName = conversations.count == 1 ? ConversationWorkbench.filename(conversations[0].title) : "Hermes-\(conversations.count)段对话"
        exporting = true
    }
}

struct WorkspaceConversationRow: View {
    let conversation: Conversation
    var projectName: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if conversation.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(HermesTheme.accent) }
                Text(conversation.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(HermesTheme.muted)
            }
            if let last = conversation.messages.last {
                Text(last.content.isEmpty ? "[图片]" : last.content).font(.subheadline).foregroundStyle(HermesTheme.muted).lineLimit(2)
            }
            if !conversation.workspaceState.tags.isEmpty {
                Text(conversation.workspaceState.tags.map { "#" + $0 }.joined(separator: "  "))
                    .font(.caption).foregroundStyle(HermesTheme.accent).lineLimit(1)
            }
            if let projectName {
                Label(projectName, systemImage: "folder").font(.caption).foregroundStyle(HermesTheme.accent).lineLimit(1)
            }
            HStack {
                Text("\(conversation.messages.count) 条消息")
                if !conversation.workspaceState.configuration.isDefault { Image(systemName: "slider.horizontal.3"); Text(conversation.workspaceState.configuration.contextLabel) }
                Spacer()
                Text(conversation.updatedAt, style: .date)
            }.font(.caption2).foregroundStyle(HermesTheme.muted)
        }.foregroundStyle(.white).padding(.vertical, 8)
    }
}
