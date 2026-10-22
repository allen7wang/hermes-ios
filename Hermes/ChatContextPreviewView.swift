import SwiftUI
import UIKit

struct ChatContextPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let preview: ChatContextPreview
    var pendingImage: Data? = nil

    private var stale: Bool {
        preview.profileID != model.activeProfileID || preview.draftKey != model.draftKey ||
        preview.rawText != model.draft || preview.plan.configuration != model.conversationConfiguration ||
        preview.fallbackModel != model.settings.model ||
        preview.sourceIDs != (model.selectedConversation?.messages ?? []).map(\.id)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("检查这次要带给 Hermes 的内容", systemImage: "eye")
                        .foregroundStyle(HermesTheme.accent)
                    LabeledContent("发送到", value: preview.profileName)
                    LabeledContent("请求模型", value: preview.effectiveModel)
                    if !preview.plan.configuration.provider.isEmpty {
                        LabeledContent("供应商", value: preview.plan.configuration.provider)
                    }
                    LabeledContent("历史消息", value: "\(preview.historyCount) 条")
                    LabeledContent("未带入", value: "\(preview.plan.omittedMessageCount) 条")
                    LabeledContent("图片", value: "\(preview.imageCount) 张")
                    Text("这里只预览内容。返回后手动发送，届时以当前草稿和设置为准；实际模型仍由服务端路由决定。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                }.listRowBackground(HermesTheme.surface)
                if stale {
                    Section {
                        Label("草稿、对话或设置已改变，请返回后重新预览。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }.listRowBackground(HermesTheme.surface)
                }
                if !preview.plan.configuration.systemPrompt.isEmpty {
                    Section("额外系统指令") {
                        DisclosureGroup("查看完整系统提示词") {
                            Text(preview.plan.configuration.systemPrompt).font(.subheadline).textSelection(.enabled)
                        }
                    }.listRowBackground(HermesTheme.surface)
                }
                Section("实际携带的消息 · 按发送顺序") {
                    ForEach(preview.plan.messages) { message in
                        InspectionMessageCard(message: message, directory: model.attachmentDirectory,
                            label: message.id == preview.inputID ? "我 · 本次输入" : message.role == .user ? "我 · 历史" : "Hermes · 历史",
                            pendingImage: message.id == preview.inputID ? pendingImage : nil,
                            isPending: message.id == preview.inputID)
                            .listRowBackground(HermesTheme.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("上下文预览").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回编辑") { dismiss() } } }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}

struct InspectionMessageCard: View {
    let message: ChatMessage
    let directory: URL
    let label: String
    var pendingImage: Data? = nil
    var isPending = false

    private var image: UIImage? {
        if isPending { return pendingImage.flatMap(UIImage.init(data:)) }
        return message.imageID.flatMap { ImageAttachmentStore.image($0, directory: directory) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(HermesTheme.accent)
            if !message.content.isEmpty { Text(message.content).font(.subheadline).textSelection(.enabled) }
            if message.imageID != nil {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Label("图片暂时无法读取，发送时可能失败", systemImage: "photo.badge.exclamationmark")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                }
            }
        }.padding(.vertical, 6)
    }
}
