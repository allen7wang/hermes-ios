import SwiftUI

struct RemoteWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    @State private var sessions: [RemoteSession] = []
    @State private var jobs: [RemoteJob] = []
    @State private var hasMore = false
    @State private var nextSessionOffset = 0
    @State private var loading = false
    @State private var busyJobID: String?
    @State private var showingNewJob = false
    @State private var loadGeneration = 0
    @State private var errorMessage: String?
    @State private var jobToRun: RemoteJob?
    @State private var jobToDelete: RemoteJob?
    @State private var editingJob: RemoteJob?
    @State private var creatingSession = false
    @State private var newSessionTitle = ""
    @State private var sessionBusy = false
    @State private var createdSession: RemoteSession?
    @State private var showingCreatedSession = false

    private var client: HermesClient { HermesClient(settings: model.settings) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("服务端内容", selection: $section) {
                    Text("会话").tag(0)
                    Text("定时任务").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(16)

                if !model.settings.isConfigured {
                    ContentUnavailableView("先连接 Hermes", systemImage: "server.rack",
                                           description: Text("在连接管理中填写服务器地址和 API 密钥。"))
                } else if section == 0 {
                    sessionList
                } else {
                    jobList
                }
            }
            .background(HermesTheme.background)
            .navigationTitle(model.activeProfileName + " · 服务端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await reload() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading || !model.settings.isConfigured)
                    .accessibilityLabel("刷新服务端内容")
                }
                if model.settings.isConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if section == 1 { showingNewJob = true }
                            else { newSessionTitle = ""; creatingSession = true }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(sessionBusy || busyJobID != nil)
                        .accessibilityLabel(section == 1 ? "新建定时任务" : "新建服务端会话")
                    }
                }
            }
            .tint(HermesTheme.accent)
            .sheet(isPresented: $showingNewJob) {
                RemoteJobEditorView(job: nil) {
                    Task { await reload() }
                }
            }
            .sheet(item: $editingJob) { job in
                RemoteJobEditorView(job: job) { Task { await reload() } }
            }
            .navigationDestination(isPresented: $showingCreatedSession) {
                if let session = createdSession {
                    RemoteSessionDetailView(session: session, client: client, draftStore: model.draftStore) { Task { await reload() } }
                }
            }
            .task { await reload() }
            .onChange(of: section) { _, _ in Task { await reload() } }
            .alert("服务端操作失败", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .alert("新建服务端会话", isPresented: $creatingSession) {
                TextField("标题（可选）", text: $newSessionTitle)
                Button("取消", role: .cancel) {}
                Button("创建") { Task { await createSession() } }
            } message: { Text("消息会保存在 Hermes 服务器上，可从其他客户端继续。") }
            .confirmationDialog("立即运行“\(jobToRun?.name ?? "")”？", isPresented: Binding(
                get: { jobToRun != nil }, set: { if !$0 { jobToRun = nil } }
            )) {
                Button("立即运行") {
                    guard let job = jobToRun else { return }
                    jobToRun = nil
                    Task { await run(job) }
                }
                Button("取消", role: .cancel) { jobToRun = nil }
            } message: { Text("此操作会在服务器上调度一次运行；已暂停的任务也会恢复。") }
            .confirmationDialog("删除“\(jobToDelete?.name ?? "")”？", isPresented: Binding(
                get: { jobToDelete != nil }, set: { if !$0 { jobToDelete = nil } }
            )) {
                Button("删除任务", role: .destructive) {
                    guard let job = jobToDelete else { return }
                    jobToDelete = nil
                    Task { await delete(job) }
                }
                Button("取消", role: .cancel) { jobToDelete = nil }
            } message: { Text("这会从服务器删除任务，并取消正在运行的任务。") }
        }
        .preferredColorScheme(.dark)
    }

    private var sessionList: some View {
        Group {
            if loading && sessions.isEmpty {
                ProgressView("正在读取服务端会话…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                ContentUnavailableView("没有服务端会话", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Hermes 服务端创建的会话会显示在这里。"))
            } else {
                List {
                    Section {
                        ForEach(sessions) { session in
                            NavigationLink {
                                RemoteSessionDetailView(session: session, client: client, draftStore: model.draftStore) {
                                    Task { await reload() }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        if session.pinned == true { Image(systemName: "pin.fill").font(.caption) }
                                        Text(session.displayTitle).fontWeight(.semibold).lineLimit(1)
                                    }
                                    if let preview = session.preview, !preview.isEmpty {
                                        Text(preview).lineLimit(2).font(.caption).foregroundStyle(HermesTheme.muted)
                                    }
                                    HStack {
                                        Text(session.source ?? "Hermes")
                                        if let count = session.messageCount { Text("· \(count) 条消息") }
                                        if let date = session.lastActive.map(Date.init(timeIntervalSince1970:)) {
                                            Text("·").padding(.horizontal, 2)
                                            Text(date, style: .relative)
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(HermesTheme.muted)
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    } header: { Text("服务器上的记录") }
                    if hasMore {
                        Button {
                            Task { await loadMoreSessions() }
                        } label: {
                            HStack {
                                Spacer()
                                if loading { ProgressView() } else { Text("加载更多会话") }
                                Spacer()
                            }
                        }
                        .disabled(loading)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await reload() }
            }
        }
    }

    private var jobList: some View {
        Group {
            if loading && jobs.isEmpty {
                ProgressView("正在读取定时任务…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if jobs.isEmpty {
                ContentUnavailableView("没有定时任务", systemImage: "calendar.badge.clock",
                                       description: Text("在 Hermes 服务端创建的任务会显示在这里。"))
            } else {
                List {
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(job.name).font(.headline)
                                Spacer()
                                Text(job.statusLabel)
                                    .font(.caption).foregroundStyle(job.isPaused || job.state == "error" ? Color.orange : Color.green)
                                Menu {
                                    Button("编辑", systemImage: "pencil") { editingJob = job }
                                    Button("删除", systemImage: "trash", role: .destructive) { jobToDelete = job }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .disabled(busyJobID != nil)
                            }
                            Text(job.scheduleDisplay ?? "未设置日程")
                                .font(.subheadline).foregroundStyle(HermesTheme.muted)
                            if let prompt = job.prompt, !prompt.isEmpty {
                                Text(prompt).font(.caption).lineLimit(2)
                            }
                            if let next = job.nextRunAt, !next.isEmpty {
                                Text("下次：\(next)").font(.caption2).foregroundStyle(HermesTheme.muted)
                            }
                            if let status = job.lastStatus, !status.isEmpty {
                                Text("上次：\(status)").font(.caption2).foregroundStyle(HermesTheme.muted)
                            }
                            if let error = job.lastError, !error.isEmpty {
                                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
                            }
                            HStack(spacing: 18) {
                                Button(job.isPaused ? "恢复" : "暂停") {
                                    Task { await toggle(job) }
                                }
                                .disabled(busyJobID != nil)
                                Button("立即运行") { jobToRun = job }
                                    .disabled(busyJobID != nil)
                                if busyJobID == job.id { ProgressView() }
                            }
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 7)
                        .listRowBackground(HermesTheme.surface)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await reload() }
            }
        }
    }

    private func reload() async {
        guard model.settings.isConfigured else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let selectedSection = section
        loading = true
        defer { if generation == loadGeneration { loading = false } }
        do {
            if selectedSection == 0 {
                let page = try await client.sessions()
                guard generation == loadGeneration else { return }
                sessions = page.data
                hasMore = page.hasMore
                nextSessionOffset = 50
            } else {
                let receivedJobs = try await client.jobs()
                guard generation == loadGeneration else { return }
                jobs = receivedJobs
            }
        } catch {
            if generation == loadGeneration { errorMessage = error.localizedDescription }
        }
    }

    private func loadMoreSessions() async {
        guard !loading, hasMore else { return }
        let generation = loadGeneration
        loading = true
        defer { if generation == loadGeneration { loading = false } }
        do {
            let page = try await client.sessions(offset: nextSessionOffset)
            guard generation == loadGeneration else { return }
            let known = Set(sessions.map(\.id))
            sessions += page.data.filter { !known.contains($0.id) }
            hasMore = page.hasMore
            nextSessionOffset += 50
        } catch {
            if generation == loadGeneration { errorMessage = error.localizedDescription }
        }
    }

    private func toggle(_ job: RemoteJob) async {
        guard busyJobID == nil else { return }
        busyJobID = job.id
        defer { busyJobID = nil }
        do {
            let updated = try await client.setJobPaused(job.id, paused: !job.isPaused)
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = updated }
        } catch { errorMessage = error.localizedDescription }
    }

    private func run(_ job: RemoteJob) async {
        guard busyJobID == nil else { return }
        busyJobID = job.id
        defer { busyJobID = nil }
        do {
            try await client.runJob(job.id)
            jobs = try await client.jobs()
        } catch { errorMessage = error.localizedDescription }
    }

    private func createSession() async {
        guard !sessionBusy else { return }
        sessionBusy = true
        defer { sessionBusy = false }
        do {
            createdSession = try await client.createSession(title: newSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines))
            showingCreatedSession = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ job: RemoteJob) async {
        guard busyJobID == nil else { return }
        busyJobID = job.id
        defer { busyJobID = nil }
        do {
            try await client.deleteJob(job.id)
            jobs.removeAll { $0.id == job.id }
        } catch { errorMessage = error.localizedDescription }
    }
}
