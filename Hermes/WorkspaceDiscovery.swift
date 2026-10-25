import Foundation

enum WorkspaceSearchKind: String, CaseIterable, Identifiable {
    case project, document, conversation, message, draft
    var id: Self { self }
    var title: String {
        switch self { case .project: "项目"; case .document: "资料"; case .conversation: "对话"; case .message: "消息"; case .draft: "草稿" }
    }
    var icon: String {
        switch self { case .project: "folder"; case .document: "doc.text"; case .conversation: "bubble.left.and.bubble.right"; case .message: "text.bubble"; case .draft: "square.and.pencil" }
    }
}

enum WorkspaceDestination: Hashable {
    case project(UUID)
    case document(projectID: UUID, documentID: UUID)
    case conversation(UUID)
    case message(LocalMessageTarget)
    case draft(UUID?)
    var id: String {
        switch self {
        case .project(let id): "project/\(id)"
        case .document(let project, let id): "document/\(project)/\(id)"
        case .conversation(let id): "conversation/\(id)"
        case .message(let target): "message/\(target.id)"
        case .draft(let id): "draft/\(id?.uuidString ?? "new")"
        }
    }
}

struct WorkspaceSearchResult: Identifiable, Equatable {
    let kind: WorkspaceSearchKind
    let destination: WorkspaceDestination
    let title: String
    let subtitle: String
    let excerpt: String
    let date: Date
    var archived = false
    var id: String { destination.id }
}

/// An ephemeral copy of current-connection data. It never contains credentials or image bytes.
struct WorkspaceDiscoverySnapshot: Equatable {
    let profileID: UUID
    let profileName: String
    let projects: [LocalProject]
    let conversations: [Conversation]
    let drafts: [String: String]

    var records: [Conversation] { conversations.filter { $0.profileID == profileID && !$0.isTrashed } }

    func draftItems(includeArchived: Bool = false) -> [WorkspaceSearchResult] {
        var result: [WorkspaceSearchResult] = []
        let newText = drafts[DraftStore.localKey(profileID: profileID, conversationID: nil)] ?? ""
        if !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.init(kind: .draft, destination: .draft(nil), title: "新对话草稿", subtitle: "尚未创建对话 · \(newText.count) 字符", excerpt: String(newText.prefix(160)), date: .distantFuture))
        }
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        for record in records where includeArchived || !record.isArchived {
            let text = drafts[DraftStore.localKey(profileID: profileID, conversationID: record.id)] ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append(.init(kind: .draft, destination: .draft(record.id), title: record.title,
                subtitle: (record.projectID.flatMap { names[$0] } ?? "未分配项目") + " · \(text.count) 字符",
                excerpt: String(text.prefix(160)), date: record.updatedAt, archived: record.isArchived))
        }
        return result.sorted(by: Self.recent)
    }

    static func recent(_ left: WorkspaceSearchResult, _ right: WorkspaceSearchResult) -> Bool {
        left.date == right.date ? left.id < right.id : left.date > right.date
    }
}

struct WorkspaceSearchReport: Equatable {
    var results: [WorkspaceSearchResult] = []
    var counts: [WorkspaceSearchKind: Int] = [:]
    var total: Int { counts.values.reduce(0, +) }
}

enum WorkspaceSearch {
    static let resultLimit = 50
    static let queryLimit = 200

    static func run(_ snapshot: WorkspaceDiscoverySnapshot, query: String, includeArchived: Bool = false) -> WorkspaceSearchReport {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= queryLimit else { return .init() }
        var report = WorkspaceSearchReport()
        func append(_ kind: WorkspaceSearchKind, destination: WorkspaceDestination, title: String,
                    subtitle: String, fields: [String], date: Date, archived: Bool = false) {
            guard !Task.isCancelled, let match = fields.first(where: { matches($0, query) }) else { return }
            report.counts[kind, default: 0] += 1
            // Keep only the most recent 50 per category while still counting every match.
            report.results.append(.init(kind: kind, destination: destination, title: title, subtitle: subtitle,
                excerpt: excerpt(match, query: query), date: date, archived: archived))
            if report.results.filter({ $0.kind == kind }).count > resultLimit {
                let oldest = report.results.indices.filter { report.results[$0].kind == kind }.max {
                    WorkspaceDiscoverySnapshot.recent(report.results[$0], report.results[$1])
                }!
                report.results.remove(at: oldest)
            }
        }
        let names = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.name) })
        for project in snapshot.projects {
            if Task.isCancelled { return .init() }
            append(.project, destination: .project(project.id), title: project.name, subtitle: "\(project.documents.count) 篇资料",
                   fields: [project.name, project.summary], date: project.updatedAt)
            for document in project.documents {
                if Task.isCancelled { return .init() }
                append(.document, destination: .document(projectID: project.id, documentID: document.id), title: document.title,
                       subtitle: project.name, fields: [document.title, document.body], date: document.updatedAt)
            }
        }
        for record in snapshot.records where includeArchived || !record.isArchived {
            if Task.isCancelled { return .init() }
            let project = record.projectID.flatMap { names[$0] } ?? "未分配项目"
            append(.conversation, destination: .conversation(record.id), title: record.title, subtitle: project,
                   fields: [record.title] + record.workspaceState.tags, date: record.updatedAt, archived: record.isArchived)
            for message in record.messages {
                if Task.isCancelled { return .init() }
                append(.message, destination: .message(.init(conversationID: record.id, messageID: message.id)),
                    title: message.role == .assistant ? "Hermes · \(record.title)" : "我 · \(record.title)",
                    subtitle: project + (message.bookmark == nil ? "" : " · 已收藏"),
                    fields: [message.content, message.bookmark?.note ?? ""], date: message.createdAt, archived: record.isArchived)
            }
        }
        for item in snapshot.draftItems(includeArchived: includeArchived) {
            let text: String
            if case .draft(let id) = item.destination { text = snapshot.drafts[DraftStore.localKey(profileID: snapshot.profileID, conversationID: id)] ?? "" }
            else { continue }
            append(.draft, destination: item.destination, title: item.title, subtitle: item.subtitle,
                   fields: [text], date: item.date, archived: item.archived)
        }
        if Task.isCancelled { return .init() }
        report.results.sort(by: WorkspaceDiscoverySnapshot.recent)
        return report
    }

    static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }

    static func excerpt(_ text: String, query: String) -> String {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) else { return String(text.prefix(160)) }
        let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 110, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + String(text[start..<end]) + (end == text.endIndex ? "" : "…")
    }
}

struct ProjectConversationCounts: Equatable {
    var active = 0
    var archived = 0
    static func aggregate(_ conversations: [Conversation]) -> [UUID: Self] {
        var result: [UUID: Self] = [:]
        for record in conversations where !record.isTrashed {
            guard let id = record.projectID else { continue }
            if record.isArchived { result[id, default: .init()].archived += 1 }
            else { result[id, default: .init()].active += 1 }
        }
        return result
    }
}
