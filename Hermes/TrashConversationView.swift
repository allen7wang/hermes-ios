import SwiftUI

struct TrashConversationView: View {
    let conversationID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    private var conversation: Conversation? { model.trashedConversations.first { $0.id == conversationID } }

    var body: some View {
        NavigationStack {
            Group {
                if let conversation {
                    List {
                        Section {
                            Label("恢复后可继续使用", systemImage: "arrow.uturn.backward")
                                .foregroundStyle(HermesTheme.accent)
                            Text("标签、收藏、草稿和图片仍在。恢复后回到原来的进行中或归档分类。")
                                .font(.subheadline).foregroundStyle(HermesTheme.muted)
                            if let date = conversation.workspaceState.trashedAt {
                                LabeledContent("移入时间") { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                            }
                            Button("恢复这段对话", systemImage: "arrow.uturn.backward") {
                                do { try model.restoreConversations([conversation.id]); dismiss() }
                                catch { failure = error.localizedDescription }
                            }.disabled(model.isSending || model.needsRecovery)
                        }.listRowBackground(HermesTheme.surface)
                        Section("原消息") {
                            ForEach(conversation.messages) { message in
                                InspectionMessageCard(message: message, directory: model.attachmentDirectory,
                                    label: message.role == .user ? "我" : "Hermes")
                                    .listRowBackground(HermesTheme.surface)
                            }
                        }
                    }.scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView("这段记录已离开回收站", systemImage: "trash",
                        description: Text("可能已经恢复或彻底删除，请返回工作台查看。"))
                }
            }
            .background(HermesTheme.background)
            .navigationTitle(conversation?.title ?? "回收站").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .alert("恢复失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("知道了", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}
