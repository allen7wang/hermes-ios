import Foundation

struct LocalProject: Identifiable, Codable, Equatable {
    static let nameLimit = 60
    static let summaryLimit = 2_000
    static let instructionsLimit = 8_000
    static let collectionLimit = 100

    var id: UUID = UUID()
    var name: String
    var summary: String
    var instructions: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        value.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= Self.nameLimit,
              !value.name.contains(where: { $0.isNewline }),
              value.summary.count <= Self.summaryLimit,
              value.instructions.count <= Self.instructionsLimit,
              createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite else { throw ProjectError.invalid }
        return value
    }

    static func validateCollection(_ projects: [Self]) throws {
        guard projects.count <= collectionLimit, Set(projects.map(\.id)).count == projects.count else { throw ProjectError.invalid }
        for project in projects {
            guard try project.validated() == project else { throw ProjectError.invalid }
        }
    }
}

enum ProjectFilter: Hashable {
    case all, unassigned, project(UUID)

    func matches(_ conversation: Conversation) -> Bool {
        switch self {
        case .all: true
        case .unassigned: conversation.projectID == nil
        case .project(let id): conversation.projectID == id
        }
    }
}

enum ProjectError: LocalizedError {
    case missing, changedContext, invalid, limit
    var errorDescription: String? {
        switch self {
        case .missing: "项目已删除或不属于当前连接，请刷新后重试。"
        case .changedContext: "当前连接已改变，请重新打开项目。"
        case .invalid: "项目名称需为 1–60 字符且不换行；说明最多 2,000 字符，额外指令最多 8,000 字符。"
        case .limit: "每个连接最多创建 100 个项目。"
        }
    }
}
