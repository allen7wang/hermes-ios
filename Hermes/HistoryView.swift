import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var renamingID: UUID?
    @State private var newTitle = ""

    private var filteredConversations: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.conversations }
        return model.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.conversations.isEmpty {
                    ContentUnavailableView(
                        "还没有对话",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("当前连接：\(model.activeProfileName)。发送第一条消息后，对话会保存在这台设备上。")
                    )
                } else if filteredConversations.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(filteredConversations) { conversation in
                            Button {
                                model.select(conversation.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(conversation.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .lineLimit(1)
                                    Text(conversation.updatedAt, style: .date)
                                        .font(.system(size: 12))
                                        .foregroundStyle(HermesTheme.muted)
                                }
                                .padding(.vertical, 6)
                            }
                            .foregroundStyle(.white)
                            .listRowBackground(
                                conversation.id == model.selectedID
                                ? HermesTheme.raised : HermesTheme.surface
                            )
                            .swipeActions {
                                Button("删除", role: .destructive) {
                                    model.delete(conversation.id)
                                }
                            }
                            .contextMenu {
                                Button("重命名", systemImage: "pencil") {
                                    newTitle = conversation.title
                                    renamingID = conversation.id
                                }
                                ShareLink(
                                    item: transcript(for: conversation),
                                    subject: Text(conversation.title),
                                    message: Text("Hermes 对话记录")
                                ) {
                                    Label("分享文本", systemImage: "square.and.arrow.up")
                                }
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    model.delete(conversation.id)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(HermesTheme.background)
            .navigationTitle(model.activeProfileName + " · 对话记录")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索标题或消息")
            .alert("重命名对话", isPresented: Binding(
                get: { renamingID != nil },
                set: { if !$0 { renamingID = nil } }
            )) {
                TextField("标题", text: $newTitle)
                Button("取消", role: .cancel) { renamingID = nil }
                Button("保存") {
                    if let renamingID { model.rename(renamingID, to: newTitle) }
                    renamingID = nil
                }
            } message: {
                Text("为这段对话设置一个方便查找的标题。")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.newConversation()
                        dismiss()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(model.isSending)
                }
            }
            .tint(HermesTheme.accent)
        }
        .preferredColorScheme(.dark)
    }

    private func transcript(for conversation: Conversation) -> String {
        let messages = conversation.messages.map { message in
            let role = message.role == .user ? "我" : "Hermes"
            let attachment = message.imageID == nil ? "" : "\n[图片]"
            return "## \(role)\n\n\(message.content)\(attachment)"
        }
        return "# \(conversation.title)\n\n" + messages.joined(separator: "\n\n")
    }
}
