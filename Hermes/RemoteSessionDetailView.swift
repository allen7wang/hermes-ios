import SwiftUI

struct RemoteSessionDetailView: View {
    @StateObject private var conversation: RemoteConversationModel
    @Environment(\.dismiss) private var dismiss
    let onChange: () -> Void
    @State private var draft = ""
    @State private var editingTitle = false
    @State private var title = ""
    @State private var deleting = false
    @State private var busy = false

    init(session: RemoteSession, client: HermesClient, onChange: @escaping () -> Void) {
        _conversation = StateObject(wrappedValue: RemoteConversationModel(session: session, client: client))
        self.onChange = onChange
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if conversation.isLoading { ProgressView("正在读取消息…") }
                        if conversation.hasOlderMessages {
                            Button {
                                let anchor = conversation.visibleMessages.first?.id
                                Task {
                                    await conversation.loadOlder()
                                    await Task.yield()
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    if conversation.isLoadingOlder { ProgressView() }
                                    else { Text("加载更早的消息") }
                                    Spacer()
                                }
                            }
                            .disabled(!conversation.canSend || busy)
                        }
                        if conversation.visibleMessages.isEmpty && !conversation.isLoading && !conversation.isSending {
                            ContentUnavailableView("开始这段会话", systemImage: "text.bubble",
                                                   description: Text("发送消息后，Hermes 会在服务端保存对话。"))
                        }
                        ForEach(conversation.visibleMessages) { message in
                            RemoteMessageCard(label: label(for: message), text: message.content)
                                .id(message.id)
                        }
                        if let input = conversation.transientInput {
                            RemoteMessageCard(label: "我", text: input)
                        }
                        if !conversation.streamedReply.isEmpty {
                            RemoteMessageCard(label: "Hermes", text: conversation.streamedReply)
                        }
                        ForEach(conversation.approvals) { approval in
                            approvalCard(approval)
                        }
                        if !conversation.progress.isEmpty {
                            HStack(spacing: 10) {
                                if conversation.isSending { ProgressView() }
                                Text(conversation.progress)
                                    .font(.caption).foregroundStyle(HermesTheme.muted)
                                Spacer()
                                if conversation.isSending {
                                    Button(conversation.isStopping ? "正在停止" : "停止") {
                                        Task { await conversation.stop() }
                                    }
                                    .disabled(conversation.isStopping)
                                }
                            }
                            .id("progress")
                        }
                    }
                    .padding(16)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .defaultScrollAnchor(.bottom)
                .refreshable { await conversation.reload() }
                .onChange(of: conversation.messages.last?.id) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: conversation.streamedReply.count) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: conversation.approvals.count) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            composer
        }
        .background(HermesTheme.background)
        .navigationTitle(conversation.session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("刷新消息", systemImage: "arrow.clockwise") { Task { await conversation.reload() } }
                    Button("重命名", systemImage: "pencil") {
                        title = conversation.session.title ?? ""
                        editingTitle = true
                    }
                    ShareLink(item: transcript) { Label("分享已加载的记录", systemImage: "square.and.arrow.up") }
                    Button("删除服务端会话", systemImage: "trash", role: .destructive) { deleting = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(!conversation.canSend || busy)
            }
        }
        .task { await conversation.reload() }
        .onDisappear { conversation.close(); onChange() }
        .alert("重命名服务端会话", isPresented: $editingTitle) {
            TextField("标题", text: $title)
            Button("取消", role: .cancel) {}
            Button("保存") {
                Task {
                    busy = true
                    _ = await conversation.rename(to: title)
                    busy = false
                }
            }
        }
        .confirmationDialog("删除“\(conversation.session.displayTitle)”及其服务端消息？", isPresented: $deleting) {
            Button("删除", role: .destructive) {
                Task {
                    busy = true
                    if await conversation.delete() { dismiss() }
                    busy = false
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("服务端操作失败", isPresented: Binding(
            get: { conversation.errorMessage != nil },
            set: { if !$0 { conversation.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { conversation.errorMessage = nil }
        } message: { Text(conversation.errorMessage ?? "") }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("继续这段服务端会话…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(12)
                .background(HermesTheme.raised, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("服务端会话消息")
            Button {
                if conversation.send(draft) { draft = "" }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(HermesTheme.background)
                    .frame(width: 44, height: 44)
                    .background(HermesTheme.accent, in: Circle())
            }
            .disabled(!conversation.canSend || busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(conversation.canSend && !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0.4)
            .accessibilityLabel("发送到服务端会话")
        }
        .padding(16)
    }

    private func approvalCard(_ approval: RemoteApproval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("需要你的审批", systemImage: "hand.raised.fill").font(.headline)
            if let description = approval.description { Text(description).font(.subheadline) }
            if let command = approval.command {
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            HStack(spacing: 18) {
                if approval.allowsOnce {
                    Button("允许本次") { Task { await conversation.resolve(approval, choice: "once") } }
                }
                Button("拒绝", role: .destructive) { Task { await conversation.resolve(approval, choice: "deny") } }
                if conversation.approvalBusy { ProgressView() }
            }
            .disabled(conversation.approvalBusy || conversation.isStopping)
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HermesTheme.raised, in: RoundedRectangle(cornerRadius: 16))
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

    private var transcript: String {
        "# \(conversation.session.displayTitle)\n\n" + conversation.visibleMessages.map {
            "## \(label(for: $0))\n\n\($0.content)"
        }.joined(separator: "\n\n")
    }
}

private struct RemoteMessageCard: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(HermesTheme.accent)
            Text(.init(text)).font(.body).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
