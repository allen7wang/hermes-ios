import Foundation

/// Append only explicitly selected references; existing positions are never reordered.
enum ProjectReferenceAddition {
    struct Row: Identifiable, Equatable {
        let conversationID: UUID
        let title: String
        let status: ProjectDocumentUsage.Status
        let beforeIDs: [UUID]
        let afterIDs: [UUID]
        var id: UUID { conversationID }
        var hasChanges: Bool { beforeIDs != afterIDs }
        var addedCount: Int { afterIDs.count - beforeIDs.count }
    }

    static func makeRow(_ conversation: Conversation, adding documentIDs: [UUID],
                        project: LocalProject, profileID: UUID) throws -> Row {
        guard conversation.profileID == profileID, conversation.projectID == project.id else {
            throw ProjectReferenceAdditionError.changed
        }
        guard !documentIDs.isEmpty else { throw ProjectReferenceAdditionError.noDocuments }
        _ = try ProjectDocument.selected(ids: documentIDs, from: project)
        let before = conversation.referenceDocumentIDs ?? []
        _ = try ProjectDocument.selected(ids: before, from: project)
        var after = before
        var seen = Set(before)
        for id in documentIDs where seen.insert(id).inserted { after.append(id) }
        _ = try ProjectDocument.selected(ids: after, from: project)
        let status: ProjectDocumentUsage.Status = conversation.isTrashed ? .trash : conversation.isArchived ? .archived : .active
        return Row(conversationID: conversation.id, title: conversation.title, status: status,
                   beforeIDs: before, afterIDs: after)
    }
}

struct ProjectReferenceAdditionReview: Identifiable {
    let id = UUID()
    let profileID: UUID
    let projectID: UUID
    let projectName: String
    let addingDocuments: [ProjectDocument]
    let documents: [ProjectDocument]
    let rows: [ProjectReferenceAddition.Row]
    var changedCount: Int { rows.filter(\.hasChanges).count }
}

enum ProjectReferenceAdditionError: LocalizedError {
    case noDocuments, noConversations, alreadyReferenced, changed
    case incompatibleConversation(title: String, reason: String)
    var errorDescription: String? {
        switch self {
        case .noDocuments: "请先选择需要添加的资料。"
        case .noConversations: "请至少选择一段需要添加引用的对话。"
        case .alreadyReferenced: "所选对话都已引用这些资料，无需重复添加。"
        case .changed: "资料、对话或所属连接、项目已改变，请返回重新检查添加方案。"
        case .incompatibleConversation(let title, let reason): "「\(title)」无法添加：\(reason)请取消这段对话或调整资料后重新检查。"
        }
    }
}
