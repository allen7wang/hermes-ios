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
}

struct Conversation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
}

struct ConnectionSettings {
    var serverURL: String
    var model: String
    var apiKey: String

    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.isEmpty
    }
}
