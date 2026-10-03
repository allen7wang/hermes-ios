import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.conversations.isEmpty {
                    ContentUnavailableView(
                        "还没有对话",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("发送第一条消息后，对话会保存在这台设备上。")
                    )
                } else {
                    List {
                        ForEach(model.conversations) { conversation in
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
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(HermesTheme.background)
            .navigationTitle("对话记录")
            .navigationBarTitleDisplayMode(.inline)
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
}
