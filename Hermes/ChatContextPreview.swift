import Foundation

enum ChatInput {
    static func text(_ raw: String, hasImage: Bool) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || hasImage else { throw ChatInputError.empty }
        guard text.count <= 100_000 else { throw ChatInputError.tooLong }
        return text
    }
}

enum ChatInputError: LocalizedError {
    case empty, tooLong
    var errorDescription: String? {
        switch self {
        case .empty: "请先输入消息或选择图片。"
        case .tooLong: "单次输入最多 100,000 字符，请缩短后再发送。"
        }
    }
}

// Shared by the actual request builder and the read-only preview.
struct PreparedChatContext {
    let configuration: ConversationConfiguration
    let messages: [ChatMessage]
    let omittedMessageCount: Int
    let project: LocalProject?
    let referenceDocuments: [ProjectDocument]
    let effectiveSystemPrompt: String

    init(messages: [ChatMessage], configuration: ConversationConfiguration, project: LocalProject? = nil,
         referenceDocumentIDs: [UUID] = []) throws {
        self.configuration = try configuration.validated()
        self.project = try project?.validated()
        referenceDocuments = try ProjectDocument.selected(ids: referenceDocumentIDs, from: self.project)
        let projectInstructions = self.project?.instructions ?? ""
        let conversationInstructions = self.configuration.systemPrompt
        var prompt: String
        if projectInstructions.isEmpty {
            prompt = conversationInstructions
        } else if conversationInstructions.isEmpty {
            prompt = "项目指令\n" + projectInstructions
        } else {
            prompt = "项目指令\n" + projectInstructions + "\n\n对话指令\n" + conversationInstructions
        }
        if !referenceDocuments.isEmpty {
            let references = referenceDocuments.enumerated().map { index, document in
                "[资料\(index + 1)] \(document.title)\n\(document.body)"
            }.joined(separator: "\n\n")
            if !prompt.isEmpty { prompt += "\n\n" }
            prompt += "用户选择的参考资料\n引用以下资料时，请标注对应的 [资料编号]。\n\n" + references
        }
        effectiveSystemPrompt = prompt
        self.messages = self.configuration.history(from: messages).map {
            var message = $0
            message.bookmark = nil
            return message
        }
        omittedMessageCount = messages.count - self.messages.count
    }
}

struct ChatContextPreview: Identifiable {
    let id = UUID()
    let profileID: UUID
    let draftKey: String
    let profileName: String
    let fallbackModel: String
    let rawText: String
    let inputID: UUID
    let sourceIDs: [UUID]
    let plan: PreparedChatContext

    var effectiveModel: String {
        plan.configuration.model.isEmpty ? (fallbackModel.isEmpty ? "hermes-agent" : fallbackModel) : plan.configuration.model
    }
    var imageCount: Int { plan.messages.filter { $0.imageID != nil }.count }
    var historyCount: Int { plan.messages.count - 1 }
}
