import SwiftUI
import PhotosUI
import UIKit

struct RemoteSessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var conversation: RemoteConversationModel
    @Environment(\.dismiss) private var dismiss
    let onChange: () -> Void
    @State private var editingTitle = false
    @State private var title = ""
    @State private var deleting = false
    @State private var busy = false
    @State private var showingSearch = false
    @State private var searchSelection: String?
    @State private var jumpRequest: TimelineJumpRequest?
    @State private var showingPrompts = false
    @State private var promptNotice = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var revision = ""

    init(session: RemoteSession, client: HermesClient, draftStore: DraftStore, onChange: @escaping () -> Void) {
        _conversation = StateObject(wrappedValue: RemoteConversationModel.open(session: session, client: client, draftStore: draftStore))
        self.onChange = onChange
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatTimeline(contextID: conversation.session.id, updateToken: timelineToken, jumpRequest: $jumpRequest) { proxy, pauseFollow in
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
                                          rendersMarkdown: message.role == "assistant", highlighted: highlightedID == message.id,
                                          failed: message.displayKind == "failed_turn")
                            .id(TimelineAnchor.message(message.id))
                            .contextMenu {
                                Button("复制消息", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
                                ShareLink(item: message.content) { Label("分享文字", systemImage: "square.and.arrow.up") }
                            }
                    }
                    if conversation.transientInput != nil || conversation.transientImage != nil {
                        RemoteMessageCard(label: "我", text: conversation.transientInput ?? "",
                                          imageData: conversation.transientImage, rendersMarkdown: false)
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
                        }
                        .id("progress")
                    }
                    if conversation.isSending {
                        Button(conversation.isStopping ? "正在停止" : "停止") {
                            Task { await conversation.stop() }
                        }
                        .disabled(conversation.isStopping)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("停止")
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
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("提示词模板", systemImage: "text.badge.plus") { showingPrompts = true }
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
        .sheet(isPresented: $showingPrompts) {
            PromptLibraryView(profileID: conversation.client.settings.profileID ?? model.activeProfileID,
                              contextTitle: "服务端 · " + conversation.session.displayTitle,
                              currentDraft: { conversation.draft }) { text, mode in
                guard conversation.client.settings.profileID == model.activeProfileID else { throw PromptError.changedContext }
                try conversation.applyPrompt(text, mode: mode)
                promptNotice = true
            }
        }
        .sheet(isPresented: $showingSearch, onDismiss: {
            if let searchSelection { jumpRequest = TimelineJumpRequest(contextID: conversation.session.id, messageID: searchSelection) }
            searchSelection = nil
        }) {
            MessageSearchView(entries: conversation.visibleMessages.map {
                MessageSearchEntry(id: $0.id, label: label(for: $0), text: $0.content)
            }, scope: "此服务端会话已加载的消息；更早记录需先加载") { searchSelection = $0 }
        }
        .task { await conversation.reload() }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            loadingPhoto = true
            let sessionID = conversation.session.id
            Task {
                // 每条退出路径都清 loading，含会话 ID 已变化的早退，避免发送按钮一直禁用。
                defer {
                    loadingPhoto = false
                    if selectedPhoto == item { selectedPhoto = nil }
                }
                do {
                    guard let original = try await item.loadTransferable(type: Data.self) else {
                        throw ImageAttachmentStore.ImageError.invalidImage
                    }
                    guard conversation.session.id == sessionID else { return }
                    conversation.attachImage(original)
                } catch {
                    guard conversation.session.id == sessionID else { return }
                    conversation.errorMessage = error.localizedDescription
                }
            }
        }
        // Keep the stream alive so an approval can be handled from the inbox after leaving this screen.
        .onDisappear { onChange() }
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

    private var highlightedID: String? {
        jumpRequest?.contextID == conversation.session.id ? jumpRequest?.messageID : nil
    }

    private var timelineToken: String {
        "\(conversation.messages.last?.id ?? "")|\(conversation.streamedReply.count)|\(conversation.approvals.count)|\(conversation.progress)|\(conversation.transientImage?.count ?? 0)"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("提示词模板", systemImage: "text.badge.plus") { showingPrompts = true }
                .font(.caption.weight(.medium)).foregroundStyle(HermesTheme.accent)
            if promptNotice {
                Text("已套用提示词，尚未发送。").font(.caption).foregroundStyle(HermesTheme.accent)
            }
            if conversation.isSending || !conversation.approvals.isEmpty {
                revisionField
            }
            if let pendingImage = conversation.pendingImage, let preview = UIImage(data: pendingImage) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 110, maxHeight: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button {
                        conversation.removePendingImage()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 23))
                            .foregroundStyle(.white, .black.opacity(0.7))
                    }
                    .accessibilityLabel("移除图片")
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Group {
                        if loadingPhoto { ProgressView().tint(HermesTheme.accent) }
                        else { Image(systemName: "photo.badge.plus") }
                    }
                    .font(.system(size: 21))
                    .foregroundStyle(HermesTheme.accent)
                    .frame(width: 38, height: 44)
                }
                .disabled(!conversation.canSend || loadingPhoto)
                .accessibilityLabel("添加图片")
                TextField("继续这段服务端会话…", text: $conversation.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(12)
                    .background(HermesTheme.raised, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("服务端会话消息")
                if conversation.isSending {
                    Button(conversation.isStopping ? "正在停止" : "停止") {
                        Task { await conversation.stop() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(conversation.isStopping)
                    .accessibilityLabel("停止")
                }
                Button {
                    if conversation.send(conversation.draft) { promptNotice = false }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .foregroundStyle(HermesTheme.background)
                        .frame(width: 44, height: 44)
                        .background(HermesTheme.accent, in: Circle())
                }
                .disabled(!canSendMessage)
                .opacity(canSendMessage ? 1 : 0.4)
                .accessibilityLabel("发送到服务端会话")
            }
        }
        .padding(16)
    }

    private var canSendMessage: Bool {
        let hasText = !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return conversation.canSend && !busy && !loadingPhoto && (hasText || conversation.pendingImage != nil)
    }

    private var revisionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("停止后放进输入框，需你再发送。不会插入当前这一轮。")
                .font(.caption2)
                .foregroundStyle(HermesTheme.muted)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("改口内容", text: $revision, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.subheadline)
                    .padding(8)
                    .background(HermesTheme.background, in: RoundedRectangle(cornerRadius: 12))
                Button("停止并放进输入框") {
                    let text = revision
                    Task {
                        if await conversation.stopAndPlaceInDraft(text) { revision = "" }
                    }
                }
                .font(.caption.weight(.semibold))
                .disabled(conversation.isStopping || revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func approvalCard(_ approval: RemoteApproval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("需要你的审批", systemImage: "hand.raised.fill").font(.headline)
            if let description = approval.description { Text(description).font(.subheadline) }
            if let command = approval.command {
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            approvalPaths(approval)
            VStack(alignment: .leading, spacing: 8) {
                if approval.allowsOnce {
                    Button("允许本次") { Task { await conversation.resolve(approval, choice: "once") } }
                }
                if approval.allowsSession && approval.command?.isEmpty == false {
                    Button("本次会话允许") { Task { await conversation.resolve(approval, choice: "session") } }
                }
                if approval.allowsAlways && approval.command?.isEmpty == false {
                    Button("始终允许") { Task { await conversation.resolve(approval, choice: "always") } }
                }
                Button("拒绝", role: .destructive) { Task { await conversation.resolve(approval, choice: "deny") } }
                if conversation.approvalBusy { ProgressView() }
            }
            .disabled(conversation.approvalBusy || conversation.isStopping)
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HermesTheme.raised, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func approvalPaths(_ approval: RemoteApproval) -> some View {
        let paths = ApprovalPathParser.paths(in: approval.command ?? "")
        if paths.isEmpty {
            Text("服务端没有返回文件差异")
                .font(.caption)
                .foregroundStyle(HermesTheme.muted)
        } else {
            Text("命令里的路径")
                .font(.caption.weight(.semibold))
            ForEach(paths, id: \.self) { path in
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
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
    var imageData: Data? = nil
    var rendersMarkdown = true
    var highlighted = false
    var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(HermesTheme.accent)
            if failed {
                Text("本轮未执行")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if highlighted { Label("查找结果", systemImage: "magnifyingglass").font(.caption).foregroundStyle(HermesTheme.accent) }
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if !text.isEmpty || imageData == nil {
                MessageContentView(text: text, rendersMarkdown: rendersMarkdown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(highlighted ? HermesTheme.accent : .clear, lineWidth: 1))
    }
}
