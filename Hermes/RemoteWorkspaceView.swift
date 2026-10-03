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
                                           description: Text("在连接设置中填写服务器地址和 API 密钥。"))
                } else if section == 0 {
                    sessionList
                } else {
                    jobList
                }
            }
            .background(HermesTheme.background)
            .navigationTitle("服务端")
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
                if section == 1 && model.settings.isConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingNewJob = true } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("新建定时任务")
                    }
                }
            }
            .tint(HermesTheme.accent)
            .sheet(isPresented: $showingNewJob) {
                NewRemoteJobView {
                    Task { await reload() }
                }
            }
            .task { await reload() }
            .onChange(of: section) { _, _ in Task { await reload() } }
            .alert("服务端操作失败", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
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
                                RemoteSessionDetailView(session: session) {
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
                                Text(job.isPaused ? "已暂停" : (job.state ?? "计划中"))
                                    .font(.caption).foregroundStyle(job.isPaused ? Color.orange : Color.green)
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
        busyJobID = job.id
        defer { busyJobID = nil }
        do {
            let updated = try await client.setJobPaused(job.id, paused: !job.isPaused)
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = updated }
        } catch { errorMessage = error.localizedDescription }
    }

    private func run(_ job: RemoteJob) async {
        busyJobID = job.id
        defer { busyJobID = nil }
        do {
            try await client.runJob(job.id)
            jobs = try await client.jobs()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct RemoteSessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: RemoteSession
    let onChange: () -> Void
    @State private var messages: [RemoteMessage] = []
    @State private var loading = true
    @State private var editingTitle = false
    @State private var title = ""
    @State private var deleting = false
    @State private var busy = false
    @State private var errorMessage: String?

    private var client: HermesClient { HermesClient(settings: model.settings) }

    var body: some View {
        Group {
            if loading {
                ProgressView("正在读取消息…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                ContentUnavailableView("没有可显示的消息", systemImage: "text.bubble")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(messages) { message in
                            if message.displayKind != "hidden" && !message.content.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(label(for: message))
                                        .font(.caption.weight(.bold)).foregroundStyle(HermesTheme.accent)
                                    Text(message.content)
                                        .font(.body).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                    .padding(16)
                }
                .refreshable { await load() }
            }
        }
        .background(HermesTheme.background)
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("刷新消息", systemImage: "arrow.clockwise") { Task { await load() } }
                    Button("重命名", systemImage: "pencil") {
                        title = session.title ?? ""
                        editingTitle = true
                    }
                    Button("删除服务端会话", systemImage: "trash", role: .destructive) { deleting = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(busy)
            }
        }
        .task { await load() }
        .alert("重命名服务端会话", isPresented: $editingTitle) {
            TextField("标题", text: $title)
            Button("取消", role: .cancel) {}
            Button("保存") { Task { await rename() } }
        }
        .confirmationDialog("删除“\(session.displayTitle)”及其服务端消息？", isPresented: $deleting) {
            Button("删除", role: .destructive) { Task { await delete() } }
            Button("取消", role: .cancel) {}
        }
        .alert("服务端操作失败", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func label(for message: RemoteMessage) -> String {
        switch message.role {
        case "user": return "我"
        case "assistant": return "Hermes"
        case "tool": return message.toolName ?? "工具"
        case "system": return "系统"
        default: return message.role
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { messages = try await client.sessionMessages(session.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func rename() async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.renameSession(session.id, title: clean)
            onChange()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func delete() async {
        busy = true
        defer { busy = false }
        do {
            try await client.deleteSession(session.id)
            onChange()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NewRemoteJobView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onCreate: () -> Void
    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = "every 1h"
    @State private var saving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("名称", text: $name)
                    TextField("让 Hermes 做什么", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("运行时间") {
                    TextField("every 1h", text: $schedule)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("示例：every 1h、every day at 9am、0 9 * * *、in 30m。具体时间按 Hermes 服务端时区计算。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                }
                Section {
                    Text("任务由 Hermes 服务端调度；创建后可在这里暂停、恢复或立即运行。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(HermesTheme.background)
            .navigationTitle("新建定时任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await create() }
                    } label: {
                        if saving { ProgressView() } else { Text("创建") }
                    }
                    .disabled(!canSave)
                }
            }
            .tint(HermesTheme.accent)
            .alert("创建失败", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .preferredColorScheme(.dark)
    }

    private func create() async {
        guard canSave else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await HermesClient(settings: model.settings).createJob(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                schedule: schedule.trimmingCharacters(in: .whitespacesAndNewlines),
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onCreate()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
