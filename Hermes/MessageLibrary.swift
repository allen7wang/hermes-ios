import Foundation

struct LocalMessageTarget: Hashable, Identifiable {
    let conversationID: UUID
    let messageID: UUID
    var id: String { conversationID.uuidString + "/" + messageID.uuidString }
}

struct MessageLibraryItem: Identifiable, Equatable {
    let id: LocalMessageTarget
    let conversationTitle: String
    let message: ChatMessage
    var roleLabel: String { message.role == .assistant ? "Hermes" : "我" }
    var preview: String {
        message.content.isEmpty && message.imageID != nil ? "[图片]" : String(message.content.prefix(160))
    }
}

enum MessageLibraryFilter: String, CaseIterable, Identifiable {
    case bookmarks, all
    var id: Self { self }
    var label: String { self == .bookmarks ? "收藏" : "全部" }
}

enum MessageLibraryRole: String, CaseIterable, Identifiable {
    case all, assistant, user
    var id: Self { self }
    var label: String {
        switch self { case .all: "全部角色"; case .assistant: "Hermes"; case .user: "我" }
    }
}

enum MessageLibrary {
    static func items(in conversations: [Conversation], query: String = "", filter: MessageLibraryFilter = .all,
                      role: MessageLibraryRole = .all) -> [MessageLibraryItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = conversations.flatMap { conversation -> [MessageLibraryItem] in
            guard !Task.isCancelled else { return [] }
            return conversation.messages.compactMap { message -> MessageLibraryItem? in
                guard !Task.isCancelled else { return nil }
                guard filter != .bookmarks || message.bookmark != nil,
                      role == .all || role.rawValue == message.role.rawValue else { return nil }
                let fields = [conversation.title, message.content, message.bookmark?.note ?? ""]
                guard query.isEmpty || fields.contains(where: {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
                }) else { return nil }
                return MessageLibraryItem(id: LocalMessageTarget(conversationID: conversation.id, messageID: message.id),
                                          conversationTitle: conversation.title, message: message)
            }
        }
        guard !Task.isCancelled else { return [] }
        return matches.sorted {
            let left = filter == .bookmarks ? $0.message.bookmark!.createdAt : $0.message.createdAt
            let right = filter == .bookmarks ? $1.message.bookmark!.createdAt : $1.message.createdAt
            return left == right ? $0.id.id < $1.id.id : left > right
        }
    }

    /// A textual quote never attaches image bytes or sends a request.
    static func quote(_ item: MessageLibraryItem) -> String {
        let text = item.message.content
        let image = item.message.imageID == nil ? "" : "\n[图片未包含在引用中]"
        let excerpt = (text.isEmpty ? "[图片]" : String(text.prefix(4_000))) + (text.count > 4_000 ? "\n…（引用已截取前 4,000 字符）" : "") + image
        return "引用自「\(item.conversationTitle)」· \(item.roleLabel)：\n" + excerpt.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
    }

    static func shareText(_ item: MessageLibraryItem) -> String {
        let image = item.message.imageID == nil ? "" : "\n[图片]"
        let note = item.message.bookmark?.note ?? ""
        return "# \(item.conversationTitle)\n\n## \(item.roleLabel)\n\n\(item.message.content)\(image)" + (note.isEmpty ? "" : "\n\n## 收藏备注\n\n\(note)")
    }
}
