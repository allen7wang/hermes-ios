import SwiftUI

struct InboxView: View {
    private struct ElevatedApproval {
        let item: InboxItem
        let choice: String
    }

    @ObservedObject var workspace: RemoteWorkspaceModel
    @EnvironmentObject private var model: AppModel
    @State private var items: [InboxItem] = []
    @State private var jobs: [RemoteJob] = []
    @State private var didLoadJobs = false
    @State private var loadingJobs = false
    @State private var resolvingID: String?
    @State private var errorText: String?
    @State private var elevatedApproval: ElevatedApproval?

    private var attentionJobs: [RemoteJob] {
        let source = didLoadJobs ? jobs : workspace.jobs
        return source.filter(Self.isAttention)
    }

    var body: some View {
        List {
            if items.isEmpty && attentionJobs.isEmpty {
                if loadingJobs {
                    ProgressView("正在读取收件箱…")
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView("没有待处理事项", systemImage: "tray",
                        description: Text("审批、完成和失败会出现在这里。"))
                        .listRowBackground(Color.clear)
                }
            }
            if !items.isEmpty {
                Section("事项") {
                    ForEach(items) { item in
                        itemRow(item)
                            .listRowBackground(HermesTheme.surface)
                    }
                }
            }
            if !attentionJobs.isEmpty {
                Section("任务") {
                    ForEach(attentionJobs) { job in
                        jobRow(job)
                            .listRowBackground(HermesTheme.surface)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(HermesTheme.background)
        .onAppear { loadItems() }
        .onReceive(NotificationCenter.default.publisher(for: InboxStore.didChange)) { _ in
            loadItems()
        }
        .task { await reloadJobs() }
        .refreshable { await reloadJobs() }
        .alert("收件箱操作失败", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("知道了", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .confirmationDialog("确认扩大授权范围？", isPresented: Binding(
            get: { elevatedApproval != nil },
            set: { if !$0 { elevatedApproval = nil } }
        ), titleVisibility: .visible) {
            if let elevatedApproval {
                Button(elevatedApproval.choice == "always" ? "确认始终允许" : "确认本会话允许",
                       role: .destructive) {
                    Task { await resolve(elevatedApproval.item, choice: elevatedApproval.choice) }
                    self.elevatedApproval = nil
                }
            }
            Button("取消", role: .cancel) { elevatedApproval = nil }
        } message: {
            Text("请先核对卡片中展示的完整命令；此授权可能对后续操作生效。")
        }
    }

    @ViewBuilder
    private func itemRow(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = workspace.sessions.first(where: { $0.id == item.sessionID }) {
                NavigationLink {
                    RemoteSessionDetailView(session: session, client: workspace.client,
                        draftStore: model.draftStore) {}
                } label: {
                    itemBody(item)
                }
            } else {
                NavigationLink {
                    InboxSessionDestination(client: workspace.client, sessionID: item.sessionID,
                        draftStore: model.draftStore)
                } label: {
                    itemBody(item)
                }
            }
            if item.kind == .approval {
                HStack(spacing: 8) {
                    if item.choices?.contains("once") ?? true {
                        Button("允许本次") { Task { await resolve(item, choice: "once") } }
                            .buttonStyle(.bordered).tint(HermesTheme.accent)
                    }
                    if item.choices?.contains("session") == true && item.command?.isEmpty == false {
                        Button("本次会话允许") { elevatedApproval = ElevatedApproval(item: item, choice: "session") }
                            .buttonStyle(.bordered).tint(HermesTheme.accent)
                    }
                    if item.choices?.contains("always") == true && item.command?.isEmpty == false {
                        Button("始终允许") { elevatedApproval = ElevatedApproval(item: item, choice: "always") }
                            .buttonStyle(.bordered).tint(HermesTheme.accent)
                    }
                    if item.choices?.contains("deny") ?? true {
                        Button("拒绝") { Task { await resolve(item, choice: "deny") } }
                            .buttonStyle(.bordered).tint(.red)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(resolvingID != nil)
                .font(.caption.weight(.medium))
            }
        }
        .padding(.vertical, 4)
    }

    private func itemBody(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Text(kindLabel(item.kind))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(kindColor(item.kind))
            }
            if !item.sessionTitle.isEmpty {
                Text(item.sessionTitle).font(.caption).foregroundStyle(HermesTheme.muted).lineLimit(1)
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(.caption).foregroundStyle(HermesTheme.muted).lineLimit(3)
            }
            if item.kind == .approval, let command = item.command, !command.isEmpty {
                Text("完整命令").font(.caption.weight(.semibold))
                Text(command).font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text(item.createdAt, style: .relative)
                .font(.caption2).foregroundStyle(HermesTheme.muted)
        }
    }

    @ViewBuilder
    private func jobRow(_ job: RemoteJob) -> some View {
        if workspace.jobs.contains(where: { $0.id == job.id }) {
            NavigationLink {
                RemoteJobDetailView(workspace: workspace, jobID: job.id)
            } label: {
                jobLabel(job)
            }
        } else {
            jobLabel(job)
        }
    }

    private func jobLabel(_ job: RemoteJob) -> some View {
        let running = job.lastStatus == "running" || job.state == "running"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(job.name).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Text(running ? "运行中" : "失败")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(running ? HermesTheme.accent : .orange)
            }
            Text(job.lastStatusLabel).font(.caption).foregroundStyle(HermesTheme.muted)
            if let error = job.lastError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(HermesTheme.muted).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func resolve(_ item: InboxItem, choice: String) async {
        guard resolvingID == nil else { return }
        guard item.profileID == workspace.client.settings.profileID else { return }
        guard let runID = item.runID, !runID.isEmpty else {
            errorText = "这条审批没有运行编号，无法提交。"
            return
        }
        resolvingID = item.id
        defer { resolvingID = nil }
        let approval = RemoteApproval(runID: runID, requestID: item.requestID, command: nil,
            description: item.detail, choices: item.choices)
        guard (approval.choices ?? ["once", "deny"]).contains(choice) else { return }
        if choice == "session" || choice == "always" {
            guard item.command?.isEmpty == false else { return }
        }
        do {
            try await workspace.client.resolveApproval(approval, choice: choice)
        } catch {
            errorText = "无法提交审批，请稍后再试。"
            return
        }
        do { try InboxStore.remove(id: item.id, profileID: item.profileID) }
        catch { errorText = "审批已提交，但无法清理本机收件箱：\(error.localizedDescription)" }
        loadItems()
    }

    private func reloadJobs() async {
        loadingJobs = items.isEmpty && attentionJobs.isEmpty
        defer { loadingJobs = false }
        do {
            jobs = try await workspace.client.jobs()
            didLoadJobs = true
        } catch {
            if !didLoadJobs { jobs = workspace.jobs }
        }
        loadItems()
    }

    private func loadItems() {
        do { items = try InboxStore.items(profileID: workspace.client.settings.profileID) }
        catch {
            items = []
            errorText = "无法读取收件箱；原文件已保留：\(error.localizedDescription)"
        }
    }

    private static func isAttention(_ job: RemoteJob) -> Bool {
        if job.lastStatus == "running" || job.state == "running" { return true }
        return ["error", "failed", "delivery_failed", "unreachable", "auth_failed"].contains(job.lastStatus ?? "")
            || job.needsAttention
    }

    private func kindLabel(_ kind: InboxItem.Kind) -> String {
        switch kind {
        case .approval: return "待审批"
        case .finished: return "已完成"
        case .failed: return "失败"
        }
    }

    private func kindColor(_ kind: InboxItem.Kind) -> Color {
        switch kind {
        case .approval: return HermesTheme.accent
        case .finished: return HermesTheme.muted
        case .failed: return .orange
        }
    }
}

private struct InboxSessionDestination: View {
    let client: HermesClient
    let sessionID: String
    let draftStore: DraftStore
    @State private var session: RemoteSession?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let session {
                RemoteSessionDetailView(session: session, client: client, draftStore: draftStore) {}
            } else if let errorText {
                ContentUnavailableView("无法打开会话", systemImage: "exclamationmark.triangle",
                    description: Text(errorText))
            } else {
                ProgressView("正在读取会话…")
            }
        }
        .task {
            guard session == nil else { return }
            do { session = try await client.session(sessionID) }
            catch { errorText = error.localizedDescription }
        }
    }
}
