import Foundation

struct ConnectionProfile: Identifiable, Codable, Equatable {
    // Retain the existing keychain account during migration; no plaintext copy is made.
    static let legacyID = UUID(uuidString: "A7361652-066C-4601-B104-3ECA81739143")!

    var id: UUID = UUID()
    var name: String
    var serverURL: String
    var model: String

    var credentialAccount: String {
        id == Self.legacyID ? "api-server-key" : "connection-\(id.uuidString)"
    }

    func settings(apiKey: String) -> ConnectionSettings {
        ConnectionSettings(serverURL: serverURL, model: model, apiKey: apiKey, profileID: id)
    }
}

struct ConnectionLibrary: Codable {
    var profiles: [ConnectionProfile]
    var activeID: UUID
    // An empty value denotes the new-conversation composer.
    var selectedConversations: [String: String] = [:]
}
