import Foundation

/// Remove only explicitly selected references; retained references keep their relative order.
enum ProjectReferenceRemoval {
    struct Row: Identifiable, Equatable {
        let conversationID: UUID
        let title: String
        let status: ProjectDocumentUsage.Status
        let beforeIDs: [UUID]
        let afterIDs: [UUID]
        var id: UUID { conversationID }
        var hasChanges: Bool { beforeIDs != afterIDs }
        var removedCount: Int { beforeIDs.count - afterIDs.count }
    }

    static func makeRow(_ conversation: Conversation, removing documentIDs: [UUID],
                        project: LocalProject, profileID: UUID) throws -> Row {
        guard conversation.profileID == profileID, conversation.projectID == project.id else {
            throw ProjectReferenceRemovalError.changed
        }
        guard !documentIDs.isEmpty else { throw ProjectReferenceRemovalError.noDocuments }
        _ = try selectedDocuments(documentIDs, in: project)
        let before = conversation.referenceDocumentIDs ?? []
        _ = try ProjectDocument.selected(ids: before, from: project)
        let removing = Set(documentIDs)
        let after = before.filter { !removing.contains($0) }
        _ = try ProjectDocument.selected(ids: after, from: project)
        let status: ProjectDocumentUsage.Status = conversation.isTrashed ? .trash : conversation.isArchived ? .archived : .active
        return Row(conversationID: conversation.id, title: conversation.title, status: status,
                   beforeIDs: before, afterIDs: after)
    }
    static func selectedDocuments(_ ids: [UUID], in project: LocalProject) throws -> [ProjectDocument] {
        guard !ids.isEmpty else { throw ProjectReferenceRemovalError.noDocuments }
        guard Set(ids).count == ids.count else { throw ProjectReferenceRemovalError.changed }
        // Removal can cover the full project library, not just a single request's five references.
        return try ProjectDocumentBatch.selected(Set(ids), in: project).sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

struct ProjectReferenceRemovalReview: Identifiable {
    let id = UUID()
    let profileID: UUID
    let projectID: UUID
    let projectName: String
    let removingDocuments: [ProjectDocument]
    let documents: [ProjectDocument]
    let rows: [ProjectReferenceRemoval.Row]
    var changedCount: Int { rows.filter(\.hasChanges).count }
}

enum ProjectReferenceRemovalError: LocalizedError {
    case noDocuments, noConversations, notReferenced, changed
    case incompatibleConversation(title: String, reason: String)
    var errorDescription: String? {
        switch self {
        case .noDocuments: "请先选择需要移除引用的资料。"
        case .noConversations: "请至少选择一段需要移除引用的对话。"
        case .notReferenced: "所选对话都未引用这些资料，无需移除。"
        case .changed: "资料、对话或所属连接、项目已改变，请返回重新检查移除方案。"
        case .incompatibleConversation(let title, let reason): "「\(title)」无法移除：\(reason)请取消这段对话或调整资料后重新检查。"
        }
    }
}
