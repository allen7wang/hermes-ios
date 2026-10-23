import Foundation

struct MessageLibraryBatchSnapshot: Identifiable {
    let id = UUID()
    let profileID: UUID
    let profileName: String
    let items: [MessageLibraryItem]
}

enum MessageLibraryBatchOperation: String, CaseIterable {
    case add, remove

    var title: String { self == .add ? "收藏所选消息" : "取消所选收藏" }
}

struct MessageLibraryBatchReport: Equatable {
    let requested: Int
    let changed: Int
    let unchanged: Int
    let notesRemoved: Int
}

/// A batch always contains complete message snapshots, never search excerpts.
enum MessageLibraryBatch {
    static let selectionLimit = 100
    static let characterLimit = 500_000
    static let exportCharacterLimit = 1_000_000

    static func ordered(_ items: [MessageLibraryItem]) -> [MessageLibraryItem] {
        items.sorted {
            $0.message.createdAt == $1.message.createdAt
                ? $0.id.id < $1.id.id
                : $0.message.createdAt > $1.message.createdAt
        }
    }

    static func characterCount(_ items: [MessageLibraryItem]) -> Int {
        items.reduce(0) { count, item in
            count + item.message.content.count + (item.message.bookmark?.note.count ?? 0)
                + item.conversationTitle.count + (item.projectName?.count ?? 0)
                + item.conversationTags.reduce(0) { $0 + $1.count }
        }
    }

    static func validate(_ items: [MessageLibraryItem]) throws {
        guard !items.isEmpty else { throw MessageLibraryBatchError.empty }
        guard Set(items.map(\.id)).count == items.count else { throw MessageLibraryBatchError.duplicates }
        guard items.count <= selectionLimit else { throw MessageLibraryBatchError.selectionLimit }
        guard characterCount(items) <= characterLimit else { throw MessageLibraryBatchError.tooLarge }
        guard items.allSatisfy({ item in
            item.id.messageID == item.message.id
                && item.message.createdAt.timeIntervalSince1970.isFinite
                && (item.message.bookmark?.createdAt.timeIntervalSince1970.isFinite ?? true)
        }) else { throw MessageLibraryBatchError.invalid }
    }

    static func report(_ items: [MessageLibraryItem], operation: MessageLibraryBatchOperation) -> MessageLibraryBatchReport {
        let changed = items.filter { operation == .add ? $0.message.bookmark == nil : $0.message.bookmark != nil }.count
        let notesRemoved = operation == .remove ? items.filter { !($0.message.bookmark?.note.isEmpty ?? true) }.count : 0
        return MessageLibraryBatchReport(requested: items.count, changed: changed,
            unchanged: items.count - changed, notesRemoved: notesRemoved)
    }

    static func markdown(_ snapshot: MessageLibraryBatchSnapshot, includeNotes: Bool = false) throws -> String {
        try validate(snapshot.items)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        let entries = ordered(snapshot.items).enumerated().map { index, item in
            let project = item.projectName.map(inline) ?? "未分组"
            let tags = item.conversationTags.isEmpty ? "无" : item.conversationTags.map(inline).joined(separator: "、")
            var text = "## \(index + 1). \(inline(item.conversationTitle))\n\n"
            text += "来源对话：\(inline(item.conversationTitle))\n\n"
            text += "角色：\(item.roleLabel) · 时间（UTC）：\(formatter.string(from: item.message.createdAt))\n\n"
            text += "项目：\(project) · 标签：\(tags) · 状态：\(item.conversationArchived ? "已归档" : "进行中")\n\n"
            text += "### 正文\n\n" + item.message.content
            if item.message.imageID != nil {
                text += "\n\n[图片未包含在此汇编中；迁移原附件请使用 Hermes JSON 备份]"
            }
            if includeNotes, let note = item.message.bookmark?.note, !note.isEmpty {
                text += "\n\n### 收藏备注\n\n" + note
            }
            return text
        }
        let text = "# \(inline(snapshot.profileName)) · 消息汇编\n\n共 \(snapshot.items.count) 条消息，按消息时间从新到旧排列。\n\n"
            + "本文保留所选消息的完整正文\(includeNotes ? "，包含已有的非空收藏备注" : "，不包含收藏备注")。恢复对话、收藏和附件请使用 Hermes JSON 备份。\n\n"
            + entries.joined(separator: "\n\n---\n\n") + "\n"
        guard text.count <= exportCharacterLimit else { throw MessageLibraryBatchError.tooLarge }
        return text
    }

    /// Metadata is one Markdown line; user-authored message and note bodies stay untouched.
    private static func inline(_ value: String) -> String {
        let punctuation = Set("\\`*_{}[]<>()#+-.!|~")
        return value.map { character -> String in
            if character.isNewline { return " " }
            return punctuation.contains(character) ? "\\" + String(character) : String(character)
        }.joined()
    }
}

enum MessageLibraryBatchError: LocalizedError {
    case empty, duplicates, selectionLimit, tooLarge, changed, invalid

    var errorDescription: String? {
        switch self {
        case .empty: "请先选择至少一条消息。"
        case .duplicates: "选择中包含重复消息，请重新选择。"
        case .selectionLimit: "每次最多整理 100 条消息，请减少选择后重试。"
        case .tooLarge: "所选文字最多 500,000 字符，生成的 Markdown 最多 1,000,000 字符；本次未截断或导出内容。"
        case .changed: "当前连接或所选消息已改变，请关闭操作面板，重新检查并选择消息。"
        case .invalid: "所选消息的标识或日期无效，请先检查本机数据。"
        }
    }
}
