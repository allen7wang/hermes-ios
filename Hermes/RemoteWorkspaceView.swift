import SwiftUI

struct RemoteWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RemoteWorkspaceContent(client: HermesClient(settings: model.settings))
            .id(model.settings)
    }
}

private struct RemoteWorkspaceContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var workspace: RemoteWorkspaceModel
    @ScaledMetric(relativeTo: .caption) private var jobFilterHeight: CGFloat = 36
    @State private var section = 0
    @State private var sessionQuery = ""
    @State private var jobQuery = ""
    @State private var pinnedOnly = false
    @State private var jobFilter = RemoteJobFilter.all
    @State private var showingNewJob = false
    @State private var creatingSession = false
    @State private var newSessionTitle = ""
    @State private var createdSession: RemoteSession?
    @State private var showingCreatedSession = false

    init(client: HermesClient) {
        _workspace = StateObject(wrappedValue: RemoteWorkspaceModel(client: client))
    }

    private var isConfigured: Bool { workspace.client.settings.isConfigured }
    private var refreshDisabled: Bool {
        !isConfigured || (section == 0 ? workspace.sessionActionsDisabled : workspace.jobActionsDisabled)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isConfigured {
                    ContentUnavailableView("先连接 Hermes", systemImage: "server.rack",
                        description: Text("在连接管理中填写服务器地址和 API 密钥。"))
                } else if section == 0 { sessionList }
                else { jobList }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Picker("服务端内容", selection: $section) {
                        Text("会话").tag(0)
                        Text("定时任务").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(height: 36)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    if isConfigured {
                        searchAndFilters
                        if let notice = workspace.notice {
                            HStack(alignment: .top) {
                                Text(notice).font(.caption)
                                Spacer()
                                Button { workspace.notice = nil } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("关闭运行提示")
                            }
                            .padding(12).background(HermesTheme.surface)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(HermesTheme.background)
            }
            .background(HermesTheme.background)
            .navigationTitle(model.activeProfileName + " · 服务端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(refreshDisabled).accessibilityLabel("刷新服务端内容")
                }
                if isConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if section == 1 { showingNewJob = true }
                            else { newSessionTitle = ""; creatingSession = true }
                        } label: { Image(systemName: "plus") }
                        .disabled(section == 0 ? workspace.sessionActionsDisabled : workspace.jobActionsDisabled)
                        .accessibilityLabel(section == 1 ? "新建定时任务" : "新建服务端会话")
                    }
                }
            }
            .tint(HermesTheme.accent)
            .sheet(isPresented: $showingNewJob) {
                RemoteJobEditorView(job: nil) { Task { await workspace.reloadJobs() } }
            }
            .navigationDestination(isPresented: $showingCreatedSession) {
                if let session = createdSession { sessionDetail(session) }
            }
            .task(id: section) { await reload() }
            .alert("服务端操作失败", isPresented: Binding(
                get: { workspace.actionError != nil }, set: { if !$0 { workspace.actionError = nil } }
            )) {
                Button("知道了", role: .cancel) { workspace.actionError = nil }
            } message: { Text(workspace.actionError ?? "") }
            .alert("新建服务端会话", isPresented: $creatingSession) {
                TextField("标题（可选）", text: $newSessionTitle)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    Task {
                        if let session = await workspace.createSession(title: newSessionTitle) {
                            createdSession = session
                            showingCreatedSession = true
                        }
                    }
                }
            } message: { Text("消息会保存在 Hermes 服务器上，可从其他客户端继续。") }
        }
        .preferredColorScheme(.dark)
    }

    private var searchAndFilters: some View {
        VStack(spacing: 10) {
            RemoteSearchField(text: section == 0 ? $sessionQuery : $jobQuery,
                prompt: section == 0 ? "搜索标题、摘要、来源或 ID" : "搜索任务名称、说明、日程或 ID")
            if section == 0 {
                HStack {
                    Text("仅搜索已加载的 \(workspace.sessions.count) 段会话")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                    Spacer()
                    if workspace.sessions.contains(where: { $0.pinned != nil }) {
                        Button {
                            pinnedOnly.toggle()
                        } label: {
                            Label(pinnedOnly ? "已置顶" : "全部", systemImage: pinnedOnly ? "pin.fill" : "pin")
                                .font(.caption.weight(.medium))
                        }
                        .accessibilityLabel(pinnedOnly ? "显示全部会话" : "仅显示置顶会话")
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RemoteJobFilter.allCases) { filter in
                            Button { jobFilter = filter } label: {
                                Text(filter.title).font(.caption.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(jobFilter == filter ? HermesTheme.accent.opacity(0.22) : HermesTheme.surface)
                                    .clipShape(Capsule())
                            }
                            .accessibilityAddTraits(jobFilter == filter ? .isSelected : [])
                        }
                    }
                }
                .frame(height: jobFilterHeight)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var sessionList: some View {
        let visible = workspace.filteredSessions(query: sessionQuery, pinnedOnly: pinnedOnly)
        return List {
            if let error = workspace.sessionsError {
                RemoteLoadBanner(message: error, hasRecords: !workspace.sessions.isEmpty,
                    disabled: workspace.sessionActionsDisabled) { Task { await workspace.reloadSessions() } }
            }
            if workspace.isLoadingSessions && workspace.sessions.isEmpty {
                ProgressView("正在读取服务端会话…")
            } else if visible.isEmpty && workspace.sessionsError == nil {
                ContentUnavailableView(workspace.sessions.isEmpty ? "没有服务端会话" : "没有匹配的会话",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text(workspace.sessions.isEmpty ? "点击右上角 + 开始一段新会话。" :
                        "试试其他关键词、切换置顶筛选，或继续加载更多记录。"))
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(visible) { session in
                    NavigationLink { sessionDetail(session) } label: {
                        sessionRow(session)
                    }
                    .listRowBackground(HermesTheme.surface)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if session.pinned != nil { pinButton(session) }
                    }
                    .contextMenu { if session.pinned != nil { pinButton(session) } }
                }
            } header: {
                if !visible.isEmpty { Text("\(visible.count) 段会话 · 置顶优先") }
            }
            if workspace.hasMoreSessions {
                Button { Task { await workspace.loadMoreSessions() } } label: {
                    HStack {
                        Spacer()
                        if workspace.isLoadingMoreSessions { ProgressView() } else { Text("加载更多会话") }
                        Spacer()
                    }
                }
                .disabled(workspace.sessionActionsDisabled)
            }
            if let date = workspace.sessionsUpdatedAt { updatedRow(date) }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await workspace.reloadSessions() }
        .scrollDismissesKeyboard(.interactively)
    }

    private var jobList: some View {
        let visible = workspace.filteredJobs(query: jobQuery, filter: jobFilter)
        return List {
            if let error = workspace.jobsError {
                RemoteLoadBanner(message: error, hasRecords: !workspace.jobs.isEmpty,
                    disabled: workspace.jobActionsDisabled) { Task { await workspace.reloadJobs() } }
            }
            if workspace.isLoadingJobs && workspace.jobs.isEmpty {
                ProgressView("正在读取定时任务…")
            } else if visible.isEmpty && workspace.jobsError == nil {
                ContentUnavailableView(workspace.jobs.isEmpty ? "没有定时任务" : "没有匹配的任务",
                    systemImage: "calendar.badge.clock",
                    description: Text(workspace.jobs.isEmpty ? "点击右上角 + 创建一个任务。" : "试试其他关键词或状态筛选。"))
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(visible) { job in
                    NavigationLink {
                        RemoteJobDetailView(workspace: workspace, jobID: job.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(job.name).font(.headline).lineLimit(2)
                                Spacer()
                                RemoteJobStatusBadge(job: job)
                            }
                            Text(job.scheduleDisplay ?? "未设置日程")
                                .font(.caption).foregroundStyle(HermesTheme.muted)
                            if let prompt = job.prompt, !prompt.isEmpty { Text(prompt).font(.caption).lineLimit(2) }
                            if job.nextRunAt != nil {
                                Text("下次：\(RemoteTimestamp.display(job.nextRunAt))")
                                    .font(.caption2).foregroundStyle(HermesTheme.muted)
                            }
                            if job.needsAttention {
                                Label("最近运行需要关注", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            } else if job.lastStatus != nil {
                                Text("上次：\(job.lastStatusLabel)").font(.caption2).foregroundStyle(HermesTheme.muted)
                            }
                        }.padding(.vertical, 5)
                    }
                    .listRowBackground(HermesTheme.surface)
                }
            } header: { if !visible.isEmpty { Text("\(visible.count) / \(workspace.jobs.count) 个任务") } }
            if let date = workspace.jobsUpdatedAt { updatedRow(date) }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await workspace.reloadJobs() }
        .scrollDismissesKeyboard(.interactively)
    }

    private func sessionRow(_ session: RemoteSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if session.pinned == true {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(HermesTheme.accent)
                        .accessibilityLabel("已置顶")
                }
                Text(session.displayTitle).fontWeight(.semibold).lineLimit(1)
                if workspace.busySessionID == session.id { ProgressView() }
            }
            if let preview = session.preview, !preview.isEmpty {
                Text(preview).lineLimit(2).font(.caption).foregroundStyle(HermesTheme.muted)
            }
            HStack {
                Text(session.source ?? "Hermes")
                if let count = session.messageCount { Text("· \(count) 条消息") }
                if let date = session.lastActive.map(Date.init(timeIntervalSince1970:)) {
                    Text("·")
                    Text(date, style: .relative)
                }
            }.font(.caption2).foregroundStyle(HermesTheme.muted)
        }.padding(.vertical, 5)
    }

    private func pinButton(_ session: RemoteSession) -> some View {
        Button {
            Task { await workspace.togglePin(session) }
        } label: {
            Label(session.pinned == true ? "取消置顶" : "置顶", systemImage: session.pinned == true ? "pin.slash" : "pin")
        }
        .tint(HermesTheme.accent).disabled(workspace.sessionActionsDisabled)
    }

    private func sessionDetail(_ session: RemoteSession) -> some View {
        RemoteSessionDetailView(session: session, client: workspace.client, draftStore: model.draftStore) {
            Task { await workspace.reloadSessions() }
        }
    }

    private func updatedRow(_ date: Date) -> some View {
        HStack {
            Text("最近刷新")
            Text(date, style: .relative)
        }.font(.caption2).foregroundStyle(HermesTheme.muted).listRowBackground(Color.clear)
    }

    private func reload() async {
        if section == 0 { await workspace.reloadSessions() } else { await workspace.reloadJobs() }
    }
}
