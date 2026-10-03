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

    init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date(), imageID: UUID? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.imageID = imageID
    }
}

struct Conversation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
    var profileID: UUID?
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
