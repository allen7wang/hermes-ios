import SwiftUI

struct EditMessageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    @State private var text: String
    @State private var keepImage: Bool
    @State private var failure: String?

    init(message: ChatMessage) {
        self.message = message
        _text = State(initialValue: message.content)
        _keepImage = State(initialValue: message.imageID != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("修改这条问题…", text: $text, axis: .vertical)
                        .lineLimit(4...12).accessibilityLabel("修改后的问题")
                    if let id = message.imageID {
                        Toggle("保留原图片", isOn: $keepImage)
                        if keepImage, let image = ImageAttachmentStore.image(id, directory: model.attachmentDirectory) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                        }
                    }
                } header: { Text("新的问题") }
                Section {
                    Label("本机对话分支", systemImage: "arrow.triangle.branch")
                    Text("保留这条问题之前的上下文，替换问题并发送到“\(model.activeProfileName)”。原对话及其后续回复会保留。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red).font(.subheadline) }
                }
            }
            .scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("修改后重新发送").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建并发送") {
                        if model.editAndResend(message.id, content: text, keepImage: keepImage) { dismiss() }
                        else {
                            failure = model.errorMessage ?? "当前无法修改这条消息，请关闭后重试。"
                            model.errorMessage = nil
                        }
                    }
                    .disabled(model.isSending || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(keepImage && message.imageID != nil)))
                }
            }
        }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}
