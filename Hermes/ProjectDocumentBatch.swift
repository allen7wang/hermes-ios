import Foundation

/// A reviewed batch uses complete document snapshots to reject stale destructive actions.
enum ProjectDocumentBatch {
    static func ordered(_ documents: [ProjectDocument]) -> [ProjectDocument] {
        documents.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    static func selected(_ ids: Set<UUID>, in project: LocalProject) throws -> [ProjectDocument] {
        guard !ids.isEmpty else { throw ProjectDocumentBatchError.empty }
        let documents = ordered(project.documents.filter { ids.contains($0.id) })
        guard documents.count == ids.count else { throw ProjectDocumentBatchError.changed }
        try ProjectDocument.validateCollection(documents)
        return documents
    }

    static func validate(_ snapshots: [ProjectDocument], in project: LocalProject) throws {
        guard !snapshots.isEmpty else { throw ProjectDocumentBatchError.empty }
        try ProjectDocument.validateCollection(snapshots)
        guard snapshots.allSatisfy({ snapshot in project.documents.contains(snapshot) }) else {
            throw ProjectDocumentBatchError.changed
        }
    }

    static func validateCapacity(_ documents: [ProjectDocument], target: LocalProject) throws {
        guard target.documents.count + documents.count <= ProjectDocument.collectionLimit,
              target.documents.reduce(0, { $0 + $1.body.count }) + documents.reduce(0, { $0 + $1.body.count }) <= ProjectDocument.projectCharacterLimit else {
            throw ProjectDocumentBatchError.capacity
        }
    }

    static func markdown(projectName: String, documents: [ProjectDocument]) throws -> String {
        guard !documents.isEmpty else { throw ProjectDocumentBatchError.empty }
        try ProjectDocument.validateCollection(documents)
        let count = documents.reduce(0) { $0 + $1.body.count }
        let header = "# \(projectName) · 资料汇编\n\n共 \(documents.count) 篇资料，正文 \(count) 字符。\n\n本文包含所选资料的标题和完整正文。恢复项目请使用 Hermes JSON 备份。\n\n"
        return header + documents.enumerated().map { index, document in
            "## \(index + 1). \(document.title)\n\n\(document.body)\n"
        }.joined(separator: "\n---\n\n")
    }
}

enum ProjectDocumentBatchError: LocalizedError {
    case empty, changed, sameProject, capacity
    var errorDescription: String? {
        switch self {
        case .empty: "请先选择至少一篇资料。"
        case .changed: "所选资料已修改或删除，请关闭操作面板，重新检查并选择资料。"
        case .sameProject: "请选择其他项目作为复制目标。"
        case .capacity: "目标项目容量不足。每个项目最多 20 篇资料、200,000 正文字符；本次尚未复制任何资料。"
        }
    }
}
