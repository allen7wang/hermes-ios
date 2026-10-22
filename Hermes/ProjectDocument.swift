import Foundation

struct ProjectDocument: Identifiable, Codable, Equatable {
    static let titleLimit = 80
    static let bodyLimit = 20_000
    static let collectionLimit = 20
    static let projectCharacterLimit = 200_000
    static let selectionLimit = 5
    static let selectionCharacterLimit = 50_000
    static let importByteLimit = 256 * 1_024

    var id: UUID = UUID()
    var title: String
    var body: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    func validated() throws -> Self {
        var value = self
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty, value.title.count <= Self.titleLimit,
              !value.title.contains(where: { $0.isNewline }),
              !value.body.isEmpty, value.body.count <= Self.bodyLimit,
              createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite else { throw ProjectDocumentError.invalid }
        return value
    }

    static func validateCollection(_ documents: [Self]) throws {
        guard documents.count <= collectionLimit,
              documents.reduce(0, { $0 + $1.body.count }) <= projectCharacterLimit,
              Set(documents.map(\.id)).count == documents.count else { throw ProjectDocumentError.collectionLimit }
        for document in documents {
            guard try document.validated() == document else { throw ProjectDocumentError.invalid }
        }
    }

    static func selected(ids: [UUID], from project: LocalProject?) throws -> [Self] {
        guard !ids.isEmpty else { return [] }
        guard ids.count <= selectionLimit, Set(ids).count == ids.count else { throw ProjectDocumentError.selection }
        guard let project else { throw ProjectDocumentError.missing }
        var documents: [Self] = []
        for id in ids {
            guard let document = project.documents.first(where: { $0.id == id }) else { throw ProjectDocumentError.missing }
            guard try document.validated() == document else { throw ProjectDocumentError.invalid }
            documents.append(document)
        }
        guard documents.reduce(0, { $0 + $1.body.count }) <= selectionCharacterLimit else { throw ProjectDocumentError.selectionTooLarge }
        return documents
    }

    static func importText(data: Data, filename: String) throws -> Self {
        guard data.count <= importByteLimit else { throw ProjectDocumentError.importTooLarge }
        let file = URL(fileURLWithPath: filename)
        guard ["txt", "md"].contains(file.pathExtension.lowercased()),
              var body = String(data: data, encoding: .utf8) else { throw ProjectDocumentError.importFormat }
        if body.unicodeScalars.first?.value == 0xFEFF { body.removeFirst() }
        guard !body.unicodeScalars.contains(where: { scalar in
            let value = scalar.value
            return (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D) || (0x7F...0x9F).contains(value)
        }) else { throw ProjectDocumentError.importFormat }
        let title = file.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return try Self(title: String(title.prefix(titleLimit)), body: body).validated()
    }
}

enum ProjectDocumentError: LocalizedError {
    case invalid, collectionLimit, missing, selection, selectionTooLarge, referencedSelectionTooLarge, importFormat, importTooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: "资料标题需为 1–80 字符且不换行，正文需为 1–20,000 字符。"
        case .collectionLimit: "每个项目最多保存 20 份资料，正文合计最多 200,000 字符，资料标识不能重复。"
        case .missing: "资料已删除或不属于当前项目，请重新选择。"
        case .selection: "每段对话最多引用 5 份资料，不能重复选择。"
        case .selectionTooLarge: "所选资料正文合计超过 50,000 字符，请取消部分引用或缩短资料。"
        case .referencedSelectionTooLarge: "此修改会使已有对话引用超过 50,000 字符，请先取消部分引用或缩短资料。"
        case .importFormat: "请选择 UTF-8 编码的 .txt 或 .md 纯文本文件，不支持二进制内容。"
        case .importTooLarge: "导入文件不能超过 256 KiB。"
        }
    }
}
