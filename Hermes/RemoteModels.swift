import Foundation

struct RemoteSession: Identifiable, Decodable, Equatable {
    let id: String
    let title: String?
    let source: String?
    let preview: String?
    let lastActive: Double?
    let messageCount: Int?
    let pinned: Bool?

    var displayTitle: String {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "未命名会话" : name
    }

    enum CodingKeys: String, CodingKey {
        case id, title, source, preview, pinned
        case lastActive = "last_active"
        case messageCount = "message_count"
    }
}

struct RemoteSessionPage: Decodable {
    let data: [RemoteSession]
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
    }
}

struct RemoteSessionResponse: Decodable { let session: RemoteSession }
struct RemoteSessionDeleteResponse: Decodable { let deleted: Bool }
struct RemoteMessagesResponse: Decodable { let data: [RemoteMessage] }

struct RemoteMessage: Identifiable, Decodable {
    let id: String
    let role: String
    let content: String
    let timestamp: Double?
    let toolName: String?
    let displayKind: String?

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
        case toolName = "tool_name"
        case displayKind = "display_kind"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numericID = try? container.decode(Int.self, forKey: .id) {
            id = String(numericID)
        } else if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else {
            id = UUID().uuidString
        }
        role = (try? container.decode(String.self, forKey: .role)) ?? "unknown"
        timestamp = try? container.decode(Double.self, forKey: .timestamp)
        toolName = try? container.decode(String.self, forKey: .toolName)
        displayKind = try? container.decode(String.self, forKey: .displayKind)
        if let text = try? container.decode(String.self, forKey: .content) {
            content = Self.redactInlineImages(text)
        } else if let parts = try? container.decode([Part].self, forKey: .content) {
            content = parts.map { part in
                if let text = part.text { return Self.redactInlineImages(text) }
                return part.type == "image_url" ? "[图片]" : "[\(part.type)]"
            }.joined(separator: "\n")
        } else {
            content = ""
        }
    }

    private static func redactInlineImages(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]+"#,
            with: "[图片]", options: .regularExpression
        )
    }

    private struct Part: Decodable {
        let type: String
        let text: String?
    }
}

struct RemoteJob: Identifiable, Decodable {
    let id: String
    let name: String
    let prompt: String?
    let scheduleDisplay: String?
    let state: String?
    let enabled: Bool?
    let nextRunAt: String?
    let lastRunAt: String?
    let lastStatus: String?

    var isPaused: Bool { enabled == false || state == "paused" }

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, state, enabled
        case scheduleDisplay = "schedule_display"
        case nextRunAt = "next_run_at"
        case lastRunAt = "last_run_at"
        case lastStatus = "last_status"
    }
}

struct RemoteJobsResponse: Decodable { let jobs: [RemoteJob] }
struct RemoteJobResponse: Decodable { let job: RemoteJob }
