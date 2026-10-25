import SwiftUI

private struct WorkspaceSearchRequest: Equatable {
    let snapshot: WorkspaceDiscoverySnapshot?
    let query: String
    let includeArchived: Bool
}

struct WorkspaceSearchView: View {
    @EnvironmentObject private var model: AppModel
    let onOpenChat: (LocalMessageTarget?) -> Void
    @State private var query: String
    @State private var includeArchived = false
    @State private var kind: WorkspaceSearchKind?
    @State private var report = WorkspaceSearchReport()
    @State private var resolved: WorkspaceSearchRequest?
    @State private var error: String?
    @State private var route: WorkspaceDestination?

    init(initialQuery: String = "", onOpenChat: @escaping (LocalMessageTarget?) -> Void) {
        _query = State(initialValue: initialQuery)
        self.onOpenChat = onOpenChat
    }

    var body: some View {
        let request = WorkspaceSearchRequest(snapshot: try? model.workspaceSnapshot(), query: query, includeArchived: includeArchived)
        let ready = resolved == request
        List {
            Section {
                Text("在「\(model.activeProfileName)」的本机内容中查找，结果可直接打开。")
                    .font(.subheadline).foregroundStyle(HermesTheme.muted)
                Toggle("包含已归档对话与草稿", isOn: $includeArchived).font(.subheadline)
                Picker("内容类型", selection: $kind) {
                    Text("全部类型").tag(WorkspaceSearchKind?.none)
                    ForEach(WorkspaceSearchKind.allCases) { Text($0.title).tag(Optional($0)) }
                }
            } footer: { Text("不含回收站、其他连接或服务端内容。消息可搜索收藏备注；项目指令与对话系统提示词不参与检索。") }
                .listRowBackground(HermesTheme.surface)
            if model.needsRecovery {
                ContentUnavailableView("本机数据需要恢复", systemImage: "externaldrive.badge.exclamationmark", description: Text("请在设置中检查备份与恢复。"))
                    .listRowBackground(Color.clear)
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("想找的内容，一处查找", systemImage: "magnifyingglass", description: Text("输入项目名、资料正文、对话标题、消息或草稿中的文字。"))
                    .listRowBackground(Color.clear)
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).count > WorkspaceSearch.queryLimit {
                Text("关键词最多 \(WorkspaceSearch.queryLimit) 字符，请缩短后重试。").foregroundStyle(.orange)
            } else if !ready {
                HStack { ProgressView(); Text("正在本机检索…").font(.subheadline) }.listRowBackground(Color.clear)
            } else if report.total == 0 || (kind != nil && report.counts[kind!, default: 0] == 0) {
                ContentUnavailableView("没有匹配的内容", systemImage: "magnifyingglass", description: Text("试试其他关键词、类型或归档范围。"))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(WorkspaceSearchKind.allCases.filter { kind == nil || kind == $0 }) { category in
                    let items = report.results.filter { $0.kind == category }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { item in
                                Button { open(item.destination, profileID: request.snapshot?.profileID) } label: { WorkspaceSearchResultRow(item: item) }
                                    .buttonStyle(.plain).disabled(model.isSending)
                                    .accessibilityIdentifier("workspace-search-\(item.id)")
                            }
                        } header: { Text("\(category.title) · \(report.counts[category, default: 0])") }
                        footer: {
                            if report.counts[category, default: 0] > WorkspaceSearch.resultLimit {
                                Text("本类展示最新 \(WorkspaceSearch.resultLimit) 条，请缩小关键词。全文参与匹配，摘要仅作摘录。")
                            }
                        }.listRowBackground(HermesTheme.surface)
                    }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
        .navigationTitle("统一检索").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索当前连接的本机内容")
        .task(id: request) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let snapshot = request.snapshot else { report = .init(); resolved = request; return }
            let task = Task.detached(priority: .userInitiated) {
                WorkspaceSearch.run(snapshot, query: request.query, includeArchived: request.includeArchived)
            }
            let value = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, model.activeProfileID == snapshot.profileID else { return }
            report = value
            resolved = request
        }
        .navigationDestination(item: $route) { destination in
            WorkspaceDetailDestination(destination: destination, profileID: model.activeProfileID, onOpenChat: onOpenChat)
        }
        .alert("暂时无法打开", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .onChange(of: model.activeProfileID) { _, _ in query = ""; route = nil; report = .init(); resolved = nil; error = nil }
    }

    private func open(_ destination: WorkspaceDestination, profileID: UUID?) {
        guard let profileID else { return }
        do {
            try model.openWorkspaceDestination(destination, profileID: profileID)
            switch destination {
            case .project, .document: route = destination
            case .message(let target): onOpenChat(target)
            default: onOpenChat(nil)
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct WorkspaceDraftListView: View {
    @EnvironmentObject private var model: AppModel
    let onOpenChat: (LocalMessageTarget?) -> Void
    @State private var includeArchived = false
    @State private var error: String?
    var body: some View {
        let snapshot = try? model.workspaceSnapshot()
        let items = snapshot?.draftItems(includeArchived: includeArchived) ?? []
        List {
            Section {
                Toggle("包含已归档草稿", isOn: $includeArchived)
            } footer: { Text("仅包含当前连接已有对话与新对话的非空本机文字草稿。新对话草稿优先，其余按对话更新时间排列；归档对话需恢复后才能发送。") }
                .listRowBackground(HermesTheme.surface)
            Section("\(items.count) 份草稿") {
                if items.isEmpty {
                    ContentUnavailableView(model.needsRecovery ? "本机数据需要恢复" : "暂无草稿", systemImage: "tray", description: Text("未发送的文字会保留在对应对话。远端草稿请在服务端会话中打开。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(items) { item in
                    Button {
                        do {
                            guard let profileID = snapshot?.profileID else { return }
                            try model.openWorkspaceDestination(item.destination, profileID: profileID)
                            onOpenChat(nil)
                        } catch { self.error = error.localizedDescription }
                    } label: { WorkspaceSearchResultRow(item: item) }
                        .buttonStyle(.plain).disabled(model.isSending || model.needsRecovery)
                }
            }.listRowBackground(HermesTheme.surface)
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("全部草稿").navigationBarTitleDisplayMode(.inline)
            .alert("暂时无法打开", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onChange(of: model.activeProfileID) { _, _ in includeArchived = false; error = nil }
    }
}
