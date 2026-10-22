import Foundation

struct ConversationConfiguration: Codable, Equatable {
    var model = ""
    var provider = ""
    var systemPrompt = ""
    // Zero means all local history; a turn starts at a user message.
    var contextTurns = 0

    var isDefault: Bool { self == Self() }
    var contextLabel: String { contextTurns == 0 ? "完整上下文" : "最近 \(contextTurns) 轮" }

    func validated() throws -> Self {
        var value = self
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        value.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        value.systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.model.count <= 200, value.provider.count <= 80,
              !value.model.contains(where: { $0.isNewline }), !value.provider.contains(where: { $0.isWhitespace }),
              value.systemPrompt.count <= 10_000, (0...50).contains(contextTurns),
              value.provider.isEmpty || !value.model.isEmpty else { throw WorkspaceError.invalidConfiguration }
        return value
    }

    func history(from messages: [ChatMessage]) -> [ChatMessage] {
        guard contextTurns > 0 else { return messages }
        let starts = messages.indices.filter { messages[$0].role == .user }
        guard !starts.isEmpty else { return messages }
        return Array(messages[starts[max(0, starts.count - contextTurns)]...])
    }
}

struct ConversationWorkspace: Codable, Equatable {
    var tags: [String] = []
    var archived = false
    var configuration = ConversationConfiguration()
    var trashedAt: Date?
    var isDefault: Bool { self == Self() }

    static func normalizedTags(_ raw: String) throws -> [String] {
        try normalizedTags(raw.components(separatedBy: CharacterSet(charactersIn: ",，、\n")))
    }

    static func normalizedTags(_ raw: [String]) throws -> [String] {
        var seen = Set<String>()
        let tags = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard tags.allSatisfy({ $0.count <= 20 && !$0.contains(where: { $0.isNewline }) }) else { throw WorkspaceError.invalidTags }
        let unique = tags.filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted }
        guard unique.count <= 8 else { throw WorkspaceError.invalidTags }
        return unique
    }

    func validate() throws {
        guard try Self.normalizedTags(tags) == tags, try configuration.validated() == configuration else { throw WorkspaceError.invalidConfiguration }
        if let trashedAt, !trashedAt.timeIntervalSince1970.isFinite { throw WorkspaceError.invalidConfiguration }
    }
}

enum ConversationScope: String, CaseIterable, Identifiable {
    case active, pinned, archived, trash
    var id: String { rawValue }
    var title: String { switch self { case .active: "进行中"; case .pinned: "已置顶"; case .archived: "已归档"; case .trash: "回收站" } }
}

enum ConversationSort: String, CaseIterable, Identifiable {
    case recent, oldest, title
    var id: String { rawValue }
    var title: String { switch self { case .recent: "最近更新"; case .oldest: "最早更新"; case .title: "标题名称" } }
}

enum ConversationWorkbench {
    static func filtered(_ conversations: [Conversation], scope: ConversationScope, query: String, tag: String?, sort: ConversationSort) -> [Conversation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.filter { conversation in
            let inScope = scope == .trash ? conversation.isTrashed : !conversation.isTrashed &&
                (scope == .archived ? conversation.isArchived : !conversation.isArchived && (scope != .pinned || conversation.isPinned))
            let hasTag = tag == nil || conversation.workspaceState.tags.contains(tag!)
            let matches = query.isEmpty || ([conversation.title] + conversation.workspaceState.tags + conversation.messages.map(\.content))
                .contains { $0.localizedStandardContains(query) }
            return inScope && hasTag && matches
        }.sorted { a, b in
            if sort == .recent && a.isPinned != b.isPinned { return a.isPinned }
            if sort == .title && a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            if a.updatedAt != b.updatedAt { return sort == .oldest ? a.updatedAt < b.updatedAt : a.updatedAt > b.updatedAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    static func markdown(_ conversations: [Conversation]) -> String {
        conversations.map { conversation in
            let tags = conversation.workspaceState.tags
            let metadata = tags.isEmpty ? "" : "标签：" + tags.joined(separator: "、") + "\n\n"
            let messages = conversation.messages.map { message in
                "## \(message.role == .user ? "我" : "Hermes")\n\n" + message.content + (message.imageID == nil ? "" : "\n\n[图片：请通过 JSON 备份迁移原附件]")
            }.joined(separator: "\n\n")
            return "# " + conversation.title.components(separatedBy: .newlines).joined(separator: " ") + "\n\n" + metadata + messages
        }.joined(separator: "\n\n---\n\n") + "\n"
    }

    static func filename(_ title: String) -> String {
        let name = title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\0")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return name.isEmpty ? "Hermes-对话" : String(name.prefix(70))
    }
}

enum WorkspaceError: LocalizedError {
    case missing, busy, archived, invalidTags, invalidConfiguration, changedContext
    var errorDescription: String? {
        switch self {
        case .missing: "所选对话已删除或不属于当前连接，请刷新后重试。"
        case .busy: "请先停止回复或等待完成，再整理对话或修改设置。"
        case .archived: "这段对话已归档，请恢复后继续发送；也可以从历史消息创建分支。"
        case .invalidTags: "最多添加 8 个标签，每个最多 20 字符；使用逗号分隔。"
        case .invalidConfiguration: "请检查设置：模型最多 200 字符，供应商最多 80 字符且不含空格，系统提示词最多 10,000 字符，上下文为 0–50 轮。指定供应商时需同时填写模型。"
        case .changedContext: "当前连接或对话已改变，请重新打开设置。"
        }
    }
}
