import SwiftUI

struct ConversationSettingsTarget: Identifiable {
    let id = UUID()
    let conversationID: UUID?
    let profileID: UUID
    let draftKey: String
}

struct ConversationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID?
    let profileID: UUID
    let draftKey: String
    @State private var title = ""
    @State private var tags = ""
    @State private var configuration = ConversationConfiguration()
    @State private var error: String?
    @State private var loaded = false

    private var contextChanged: Bool { model.draftKey != draftKey || model.activeProfileID != profileID }
    private var canSave: Bool {
        !contextChanged && !model.isSending && !model.needsRecovery &&
        (try? configuration.validated()) != nil && (try? ConversationWorkspace.normalizedTags(tags)) != nil &&
        (conversationID == nil || (!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 80))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(conversationID == nil ? "为下一段对话做好准备" : "让这段对话更有条理", systemImage: "slider.horizontal.3")
                        .foregroundStyle(HermesTheme.accent)
                    Text(conversationID == nil ? "设置按当前连接保存，供之后的新对话使用。已有对话保持自己的设置。" : "修改只影响此对话之后的请求；已有消息和草稿会保留。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                }.listRowBackground(HermesTheme.surface)
                if conversationID != nil {
                    Section("整理") {
                        TextField("对话标题", text: $title).accessibilityIdentifier("conversation-title")
                        TextField("标签，以逗号分隔", text: $tags).accessibilityIdentifier("conversation-tags")
                        Text("最多 8 个标签，每个最多 20 字符。归档不会删除消息、图片或草稿。")
                            .font(.caption).foregroundStyle(HermesTheme.muted)
                    }.listRowBackground(HermesTheme.surface)
                }
                Section {
                    TextField("留空则使用连接的模型", text: $configuration.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("conversation-model")
                    TextField("供应商（可选，例如 anthropic）", text: $configuration.provider)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("模型") } footer: {
                    Text("实际选择由服务器路由决定。使用具体模型时可同时指定供应商；只填模型需服务器支持直接模型选择。这里不会修改服务端会话的模型。")
                }.listRowBackground(HermesTheme.surface)
                Section {
                    TextEditor(text: $configuration.systemPrompt).frame(minHeight: 130)
                        .scrollContentBackground(.hidden).accessibilityLabel("系统提示词")
                        .accessibilityIdentifier("conversation-system-prompt")
                    HStack {
                        Button("清空") { configuration.systemPrompt = "" }.disabled(configuration.systemPrompt.isEmpty)
                        Spacer()
                        Text("\(configuration.systemPrompt.count) / 10,000").font(.caption).foregroundStyle(HermesTheme.muted)
                    }
                } header: { Text("系统提示词") } footer: {
                    Text("每次请求时作为额外指令发送给 Hermes，不替代服务器自身的核心指令。不要在这里保存密钥。")
                }.listRowBackground(HermesTheme.surface)
                Section {
                    Stepper(value: $configuration.contextTurns, in: 0...50) {
                        LabeledContent("携带历史", value: configuration.contextLabel)
                    }.accessibilityIdentifier("conversation-context")
                    Text("0 表示完整历史；其他值从最近的用户问题开始，携带对应轮次的问答。只限制发送内容，不删除本机历史，也不控制服务端已有的记忆。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                }.listRowBackground(HermesTheme.surface)
                if contextChanged {
                    Text("当前连接或对话已改变，请关闭后重新打开设置。")
                        .foregroundStyle(.orange).listRowBackground(HermesTheme.surface)
                }
            }
            .scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle(conversationID == nil ? "新对话默认设置" : "对话设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try model.saveConversationSettings(title: title, tags: tags, configuration: configuration,
                                                               expectedDraftKey: draftKey, profileID: profileID)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!canSave).accessibilityIdentifier("save-conversation-settings")
                }
            }
            .alert("无法保存设置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                title = model.selectedConversation?.title ?? ""
                tags = model.selectedConversation?.workspaceState.tags.joined(separator: "，") ?? ""
                configuration = model.conversationConfiguration
            }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}
