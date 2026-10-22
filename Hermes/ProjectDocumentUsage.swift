import Foundation

/// Current saved selections only; message text cannot establish a document reference.
enum ProjectDocumentUsage {
    enum Status: String, CaseIterable, Hashable {
        case active, archived, trash
        var title: String { switch self { case .active: "进行中"; case .archived: "已归档"; case .trash: "回收站" } }
        var order: Int { switch self { case .active: 0; case .archived: 1; case .trash: 2 } }
    }

    struct Slot: Equatable, Hashable {
        let documentID: UUID
        let number: Int
    }

    struct Reference: Identifiable, Equatable, Hashable {
        let conversationID: UUID
        let title: String
        let status: Status
        let slots: [Slot]
        var id: UUID { conversationID }
    }

    static func references(documentIDs: Set<UUID>, projectID: UUID, profileID: UUID,
                           conversations: [Conversation]) -> [Reference] {
        guard !documentIDs.isEmpty else { return [] }
        var seenConversations = Set<UUID>()
        return conversations.compactMap { conversation -> Reference? in
            guard conversation.projectID == projectID, conversation.profileID == profileID else { return nil }
            var seenDocuments = Set<UUID>()
            let slots = (conversation.referenceDocumentIDs ?? []).enumerated().compactMap { index, id -> Slot? in
                guard documentIDs.contains(id), seenDocuments.insert(id).inserted else { return nil }
                return Slot(documentID: id, number: index + 1)
            }
            guard !slots.isEmpty, seenConversations.insert(conversation.id).inserted else { return nil }
            let status: Status = conversation.isTrashed ? .trash : conversation.isArchived ? .archived : .active
            return Reference(conversationID: conversation.id, title: conversation.title, status: status, slots: slots)
        }.sorted {
            if $0.status.order != $1.status.order { return $0.status.order < $1.status.order }
            return $0.conversationID.uuidString < $1.conversationID.uuidString
        }
    }

    static func forDocument(_ id: UUID, in references: [Reference]) -> [Reference] {
        references.compactMap { reference in
            let slots = reference.slots.filter { $0.documentID == id }
            guard !slots.isEmpty else { return nil }
            return Reference(conversationID: reference.conversationID, title: reference.title,
                             status: reference.status, slots: slots)
        }
    }

    static func filtered(_ documents: [ProjectDocument], query: String, filter: ProjectDocumentUsageFilter,
                         sort: ProjectDocumentUsageSort, references: [Reference]) -> [ProjectDocument] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var conversationsByDocument: [UUID: Set<UUID>] = [:]
        for reference in references {
            for slot in reference.slots { conversationsByDocument[slot.documentID, default: []].insert(reference.conversationID) }
        }
        let matching = documents.filter { document in
            let referenced = !(conversationsByDocument[document.id] ?? []).isEmpty
            let inScope = filter == .all || (filter == .referenced ? referenced : !referenced)
            return inScope && (query.isEmpty || [document.title, document.body].contains { $0.localizedStandardContains(query) })
        }
        let recent = ProjectDocumentBatch.ordered(matching)
        guard sort != .recent else { return recent }
        return recent.sorted { a, b in
            if sort == .title {
                let comparison = a.title.localizedStandardCompare(b.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            } else {
                let aCount = conversationsByDocument[a.id]?.count ?? 0
                let bCount = conversationsByDocument[b.id]?.count ?? 0
                if aCount != bCount { return aCount > bCount }
            }
            return a.updatedAt == b.updatedAt ? a.id.uuidString < b.id.uuidString : a.updatedAt > b.updatedAt
        }
    }
}

enum ProjectDocumentUsageFilter: String, CaseIterable, Identifiable {
    case all, referenced, unreferenced
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部资料"; case .referenced: "已引用"; case .unreferenced: "未引用" } }
}

enum ProjectDocumentUsageSort: String, CaseIterable, Identifiable {
    case recent, title, mostReferenced
    var id: String { rawValue }
    var title: String { switch self { case .recent: "最近更新"; case .title: "标题名称"; case .mostReferenced: "引用对话最多" } }
}

struct ProjectDocumentDeletionReview: Identifiable {
    let id = UUID()
    let profileID: UUID
    let projectID: UUID
    let projectName: String
    let documents: [ProjectDocument]
    let references: [ProjectDocumentUsage.Reference]
}

enum ProjectDocumentUsageError: LocalizedError {
    case changedReferences
    var errorDescription: String? {
        "资料的引用或所属连接、项目已改变，请关闭删除检查，重新查看后再操作。"
    }
}
