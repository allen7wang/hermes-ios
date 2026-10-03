import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @State private var showingHistory = false
    @State private var showingSettings = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingImage: Data?
    @State private var loadingPhoto = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    if let conversation = model.selectedConversation {
                        LazyVStack(spacing: 20) {
                            ForEach(conversation.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            if !model.streamedReply.isEmpty {
                                MessageBubble(message: ChatMessage(
                                    role: .assistant,
                                    content: model.streamedReply
                                ))
                            }
                            if model.isSending { thinkingIndicator.id("thinking") }
                            else if conversation.messages.last?.role == .user {
                                Button {
                                    model.retryLastResponse()
                                } label: {
                                    Label("重试回复", systemImage: "arrow.clockwise")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(HermesTheme.accent)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 26)
                        .padding(.bottom, 24)
                    } else {
                        welcome
                            .frame(maxWidth: .infinity, minHeight: 480)
                    }
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.selectedConversation?.messages.count) { _, _ in
                    if let id = model.selectedConversation?.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .onChange(of: model.isSending) { _, sending in
                    if sending {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("thinking", anchor: .bottom) }
                    } else if let id = model.selectedConversation?.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .onChange(of: model.streamedReply.count) { _, _ in
                    if model.isSending { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }

            composer
        }
        .background(HermesTheme.background.ignoresSafeArea())
        .sheet(isPresented: $showingHistory) { HistoryView() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .task { await model.checkConnection() }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            loadingPhoto = true
            Task {
                do {
                    guard let original = try await item.loadTransferable(type: Data.self) else {
                        throw ImageAttachmentStore.ImageError.invalidImage
                    }
                    pendingImage = try ImageAttachmentStore.prepare(original)
                } catch {
                    model.errorMessage = error.localizedDescription
                }
                loadingPhoto = false
                selectedPhoto = nil
            }
        }
        .alert("连接或发送失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { showingHistory = true } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 42, height: 42)
            }
            .accessibilityLabel("对话记录")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .foregroundStyle(HermesTheme.accent)
                    Text("HERMES")
                        .tracking(2.2)
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                Button {
                    if model.settings.isConfigured {
                        Task { await model.checkConnection() }
                    } else {
                        showingSettings = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.connectionState == .connected ? Color.green : HermesTheme.muted)
                            .frame(width: 6, height: 6)
                        Text(connectionLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(HermesTheme.muted)
                    }
                }
                .accessibilityLabel("连接状态：\(connectionLabel)，点按重新检测")
            }
            Spacer()
            Button { model.newConversation() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18))
                    .frame(width: 42, height: 42)
            }
            .disabled(model.isSending)
            .accessibilityLabel("新对话")
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18))
                    .frame(width: 42, height: 42)
            }
            .accessibilityLabel("连接设置")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var connectionLabel: String {
        switch model.connectionState {
        case .unconfigured: "等待连接"
        case .checking: "正在检测"
        case .connected: "已连接"
        case .offline: "连接失败"
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)
            ZStack {
                Circle()
                    .fill(HermesTheme.accent.opacity(0.08))
                    .frame(width: 160, height: 160)
                Circle()
                    .stroke(HermesTheme.accent.opacity(0.25), lineWidth: 1)
                    .frame(width: 126, height: 126)
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 58, weight: .ultraLight))
                    .foregroundStyle(HermesTheme.accent)
            }
            Text("你的 Hermes，随身同行")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .padding(.top, 28)
            Text(model.settings.isConfigured
                 ? "开始一段对话，继续你的工作。"
                 : "先连接你的 Hermes Agent，然后开始对话。")
                .font(.system(size: 14))
                .foregroundStyle(HermesTheme.muted)
                .padding(.top, 10)

            if !model.settings.isConfigured {
                Button { showingSettings = true } label: {
                    Label("连接 Hermes", systemImage: "link")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HermesTheme.background)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 13)
                        .background(HermesTheme.accent, in: Capsule())
                }
                .padding(.top, 32)
            } else {
                VStack(spacing: 10) {
                    suggestion("帮我总结今天的工作")
                    suggestion("看看现在有什么需要处理")
                }
                .padding(.top, 34)
            }
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .foregroundStyle(.white)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            draft = text
        } label: {
            HStack {
                Image(systemName: "sparkle")
                    .foregroundStyle(HermesTheme.accent)
                Text(text)
                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 11))
                    .foregroundStyle(HermesTheme.muted)
            }
            .font(.system(size: 13))
            .padding(15)
            .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 350)
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 10) {
            ProgressView().tint(HermesTheme.accent)
            Text(model.toolStatus ?? (model.streamedReply.isEmpty
                                      ? "Hermes 正在思考…" : "正在生成回复…"))
                .font(.system(size: 13))
                .foregroundStyle(HermesTheme.muted)
                .lineLimit(1)
            Spacer()
            Button("停止") { model.cancelSend() }
                .font(.system(size: 13))
                .foregroundStyle(HermesTheme.accent)
        }
        .padding(.horizontal, 14)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pendingImage, let preview = UIImage(data: pendingImage) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 110, maxHeight: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button {
                        self.pendingImage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 23))
                            .foregroundStyle(.white, .black.opacity(0.7))
                    }
                    .accessibilityLabel("移除图片")
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Group {
                        if loadingPhoto { ProgressView().tint(HermesTheme.accent) }
                        else { Image(systemName: "photo.badge.plus") }
                    }
                    .font(.system(size: 21))
                    .foregroundStyle(HermesTheme.accent)
                    .frame(width: 38, height: 44)
                }
                .disabled(model.isSending || loadingPhoto)
                .accessibilityLabel("添加图片")

                TextField("给 Hermes 发送消息…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 15))
                    .tint(HermesTheme.accent)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 13)
                    .background(HermesTheme.raised, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("消息内容")

                Button {
                    if model.settings.isConfigured {
                        if model.send(draft, imageData: pendingImage) {
                            draft = ""
                            pendingImage = nil
                        }
                    } else {
                        showingSettings = true
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(HermesTheme.background)
                        .frame(width: 44, height: 44)
                        .background(HermesTheme.accent, in: Circle())
                }
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.45)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(HermesTheme.background)
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil)
            && !model.isSending && !loadingPhoto
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user { Spacer(minLength: 42) }
            if message.role == .assistant {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(HermesTheme.accent)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 10) {
                if let imageID = message.imageID,
                   let image = ImageAttachmentStore.image(imageID) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if !message.content.isEmpty {
                    Text(.init(message.content))
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(
                message.role == .user ? HermesTheme.raised : HermesTheme.surface,
                in: RoundedRectangle(cornerRadius: 18)
            )
            if message.role == .assistant { Spacer(minLength: 24) }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }
}
