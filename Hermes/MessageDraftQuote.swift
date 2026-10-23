import Foundation

struct MessageDraftQuoteDestination: Equatable {
    let conversationID: UUID?
    let title: String
    let projectID: UUID?
    let projectName: String?
}

struct MessageDraftQuoteSnapshot: Identifiable {
    let id = UUID()
    let source: MessageLibraryBatchSnapshot
    let draftKey: String
    let destination: MessageDraftQuoteDestination
    let draftText: String
}

enum MessageDraftQuote {
    static let draftLimit = 100_000

    /// Quoting is a reversible text transformation. Images and private notes are never loaded.
    static func referenceText(_ source: MessageLibraryBatchSnapshot) throws -> String {
        let markdown = try MessageLibraryBatch.markdown(source, includeNotes: false)
        let reference = markdown.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        guard reference.count <= draftLimit else { throw MessageDraftQuoteError.draftTooLong }
        return reference
    }

    static func draft(current: String, reference: String, mode: PromptDraftMode) throws -> String {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MessageDraftQuoteError.invalid }
        guard reference.count <= draftLimit else { throw MessageDraftQuoteError.draftTooLong }
        let next = mode == .replace || current.isEmpty ? reference : current + "\n\n" + reference
        guard next.count <= draftLimit else { throw MessageDraftQuoteError.draftTooLong }
        return next
    }
}

enum MessageDraftQuoteError: LocalizedError {
    case changed, draftTooLong, invalid, archivedDestination

    var errorDescription: String? {
        switch self {
        case .changed: "当前连接、目标对话、草稿或所选消息已改变，请关闭检查页后重新选择。"
        case .draftTooLong: "完整引用与最终草稿均最多 100,000 字符。请减少所选消息；若仅追加后超限，可改用替换。本次未截断或写入内容。"
        case .invalid: "引用需包含非空文字，请重新检查所选消息。"
        case .archivedDestination: "目标对话已归档，请先恢复对话，或选择进行中的对话及新对话草稿。"
        }
    }
}
