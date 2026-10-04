import SwiftUI

struct RemoteSessionDetailView: View {
    @StateObject private var conversation: RemoteConversationModel
    @Environment(\.dismiss) private var dismiss
    let onChange: () -> Void
    @State private var editingTitle = false
    @State private var title = ""
    @State private var deleting = false
    @State private var busy = false
    @State private var showingSearch = false
    @State private var searchSelection: String?
    @State private var jumpID: String?
    @State private var highlightedID: String?

    init(session: RemoteSession, client: HermesClient, draftStore: DraftStore, onChange: @escaping () -> Void) {
        _conversation = StateObject(wrappedValue: RemoteConversationModel(session: session, client: client, draftStore: draftStore))
        self.onChange = onChange
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatTimeline(contextID: conversation.session.id, updateToken: timelineToken, jumpID: $jumpID) { proxy, pauseFollow in
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.isLoading { ProgressView("正在读取消息…") }
                    if conversation.hasOlderMessages {
                        Button {
                            pauseFollow()
                            let anchor = conversation.visibleMessages.first?.id
                            Task {
                                await conversation.loadOlder()
                                await Task.yield()
                                if let anchor { proxy.scrollTo(TimelineAnchor.message(anchor), anchor: .top) }
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
                        RemoteMessageCard(label: label(for: message), text: message.content,
                                          rendersMarkdown: message.role == "assistant", highlighted: highlightedID == message.id)
                            .id(TimelineAnchor.message(message.id))
                            .contextMenu {
                                Button("复制消息", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
                                ShareLink(item: message.content) { Label("分享文字", systemImage: "square.and.arrow.up") }
                            }
                    }
                    if let input = conversation.transientInput {
                        RemoteMessageCard(label: "我", text: input, rendersMarkdown: false)
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
            }
            .refreshable { await conversation.reload() }
            composer
        }
        .background(HermesTheme.background)
        .navigationTitle(conversation.session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("查找已加载消息", systemImage: "magnifyingglass") { showingSearch = true }
                        .disabled(conversation.visibleMessages.isEmpty)
                    Button("刷新消息", systemImage: "arrow.clockwise") { Task { await conversation.reload() } }
                        .disabled(!conversation.canSend || busy)
                    Button("重命名", systemImage: "pencil") {
                        title = conversation.session.title ?? ""
                        editingTitle = true
                    }.disabled(!conversation.canSend || busy)
                    ShareLink(item: transcript) { Label("分享已加载的记录", systemImage: "square.and.arrow.up") }
                    Button("删除服务端会话", systemImage: "trash", role: .destructive) { deleting = true }
                        .disabled(!conversation.canSend || busy)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("服务端会话操作")
            }
        }
        .sheet(isPresented: $showingSearch, onDismiss: {
            if let searchSelection { highlightedID = searchSelection; jumpID = searchSelection }
            searchSelection = nil
        }) {
            MessageSearchView(entries: conversation.visibleMessages.map {
                MessageSearchEntry(id: $0.id, label: label(for: $0), text: $0.content)
            }, scope: "此服务端会话已加载的消息；更早记录需先加载") { searchSelection = $0 }
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

    private var timelineToken: String {
        "\(conversation.messages.last?.id ?? "")|\(conversation.streamedReply.count)|\(conversation.approvals.count)|\(conversation.progress)"
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("继续这段服务端会话…", text: $conversation.draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(12)
                .background(HermesTheme.raised, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("服务端会话消息")
            Button {
                _ = conversation.send(conversation.draft)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(HermesTheme.background)
                    .frame(width: 44, height: 44)
                    .background(HermesTheme.accent, in: Circle())
            }
            .disabled(!conversation.canSend || busy || conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(conversation.canSend && !busy && !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0.4)
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
    var rendersMarkdown = true
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(HermesTheme.accent)
            if highlighted { Label("查找结果", systemImage: "magnifyingglass").font(.caption).foregroundStyle(HermesTheme.accent) }
            MessageContentView(text: text, rendersMarkdown: rendersMarkdown)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(highlighted ? HermesTheme.accent : .clear, lineWidth: 1))
    }
}
