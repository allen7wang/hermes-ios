import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id: UUID = UUID()
    let role: Role
    let content: String
    let createdAt: Date
    var imageID: UUID?
    var bookmark: MessageBookmark?

    init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date(), imageID: UUID? = nil, bookmark: MessageBookmark? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.imageID = imageID
        self.bookmark = bookmark
    }
}

struct MessageBookmark: Codable, Equatable {
    static let noteLimit = 2_000
    let createdAt: Date
    var note: String
}

struct Conversation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
    var profileID: UUID?
    var pinned: Bool?

    var isPinned: Bool { pinned == true }
}

struct ConnectionSettings: Hashable {
    var serverURL: String
    var model: String
    var apiKey: String
    var profileID: UUID? = nil

    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.isEmpty
    }
}
