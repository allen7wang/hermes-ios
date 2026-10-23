import Foundation

/// An in-memory review of the source messages and the chosen destination project.
struct MessageProjectCapture: Identifiable {
    let id = UUID()
    let source: MessageLibraryBatchSnapshot
    let project: LocalProject
}

enum MessageProjectCaptureText {
    static let prefillLimit = 100_000

    static func initialTitle(_ source: MessageLibraryBatchSnapshot) -> String {
        String("消息汇编 · \(source.items.count)条".prefix(ProjectDocument.titleLimit))
    }

    static func initialBody(_ source: MessageLibraryBatchSnapshot) throws -> String {
        guard source.items.contains(where: { !$0.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MessageProjectCaptureError.noText
        }
        let body = try MessageLibraryBatch.markdown(source, includeNotes: false)
        guard body.count <= prefillLimit else { throw MessageProjectCaptureError.tooLarge }
        return body
    }

    static func document(title: String, body: String) throws -> ProjectDocument {
        try ProjectDocument(title: title, body: body).validated()
    }

    static func validateCapacity(_ document: ProjectDocument, in project: LocalProject) throws {
        try ProjectDocument.validateCollection(project.documents + [document.validated()])
    }
}

enum MessageProjectCaptureError: LocalizedError {
    case changed, noText, tooLarge

    var errorDescription: String? {
        switch self {
        case .changed: "来源消息、当前连接或目标项目已改变，当前编辑输入仍保留。请复制需要的内容，再重新检查后保存。"
        case .noText: "请至少选择一条包含文字正文的消息。图片不会自动转成资料，收藏备注不参与采集。"
        case .tooLarge: "完整消息汇编超过 100,000 字符，请减少所选消息后重试。内容没有截断，项目资料正文保存上限仍为 20,000 字符。"
        }
    }
}
