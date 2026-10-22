import Foundation

/// Plans an explicit change to current saved selections, without rewriting historical messages.
enum ProjectReferenceReplacement {
    struct Row: Identifiable, Equatable {
        let conversationID: UUID
        let title: String
        let status: ProjectDocumentUsage.Status
        let beforeIDs: [UUID]
        let afterIDs: [UUID]
        var id: UUID { conversationID }
    }

    static func replacing(_ ids: [UUID], sourceID: UUID, targetID: UUID) throws -> [UUID] {
        guard sourceID != targetID else { throw ProjectReferenceReplacementError.sameDocument }
        guard ids.contains(sourceID) else { throw ProjectReferenceReplacementError.missingReference }
        var seen = Set<UUID>()
        return ids.map { $0 == sourceID ? targetID : $0 }.filter { seen.insert($0).inserted }
    }

    static func makeRow(_ conversation: Conversation, sourceID: UUID, targetID: UUID,
                        project: LocalProject, profileID: UUID) throws -> Row {
        guard conversation.profileID == profileID, conversation.projectID == project.id else {
            throw ProjectReferenceReplacementError.changed
        }
        guard sourceID != targetID else { throw ProjectReferenceReplacementError.sameDocument }
        guard project.documents.contains(where: { $0.id == sourceID }),
              project.documents.contains(where: { $0.id == targetID }) else { throw ProjectDocumentError.missing }
        let beforeIDs = conversation.referenceDocumentIDs ?? []
        _ = try ProjectDocument.selected(ids: beforeIDs, from: project)
        let afterIDs = try replacing(beforeIDs, sourceID: sourceID, targetID: targetID)
        _ = try ProjectDocument.selected(ids: afterIDs, from: project)
        let status: ProjectDocumentUsage.Status = conversation.isTrashed ? .trash : conversation.isArchived ? .archived : .active
        return Row(conversationID: conversation.id, title: conversation.title, status: status,
                   beforeIDs: beforeIDs, afterIDs: afterIDs)
    }
}

struct ProjectReferenceReplacementReview: Identifiable {
    let id = UUID()
    let profileID: UUID
    let projectID: UUID
    let projectName: String
    let source: ProjectDocument
    let target: ProjectDocument
    let documents: [ProjectDocument]
    let rows: [ProjectReferenceReplacement.Row]
}

enum ProjectReferenceReplacementError: LocalizedError {
    case sameDocument, emptySelection, missingReference, changed
    var errorDescription: String? {
        switch self {
        case .sameDocument: "请选择当前项目中的另一篇资料作为替换目标。"
        case .emptySelection: "请至少选择一段需要替换当前引用的对话。"
        case .missingReference: "选中的对话已不再引用原资料，请重新检查。"
        case .changed: "资料、对话或所属连接、项目已改变，请关闭替换检查，重新查看后再操作。"
        }
    }
}
