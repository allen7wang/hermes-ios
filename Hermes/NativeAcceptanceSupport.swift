#if DEBUG
import Foundation

/// Opt-in fixtures for the separate UI test process. Release builds contain none of this code.
@MainActor
enum NativeAcceptanceSupport {
    static func makeModel() -> AppModel {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HERMES_UI_TESTING"] == "1",
              let run = environment["HERMES_UI_RUN"], UUID(uuidString: run) != nil else {
            return AppModel()
        }
        do {
            let defaults = UserDefaults(suiteName: "HermesUITests." + run)!
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UITests/" + run, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("connections.json").path) {
                try seed(directory: directory, empty: environment["HERMES_UI_EMPTY"] == "1")
            }
            // Give the system Files provider a visible local folder before the first export.
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try Data("Isolated native acceptance files only.".utf8)
                .write(to: documents.appendingPathComponent("Acceptance-location.txt"), options: .atomic)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AcceptanceDenyNetwork.self]
            let model = AppModel(defaults: defaults, directory: directory,
                                 credentials: AcceptanceCredentials(), sessionConfiguration: configuration)
            if environment["HERMES_UI_DRAFT_FAILURE"] == "1" {
                let drafts = directory.appendingPathComponent("drafts.json")
                try FileManager.default.removeItem(at: drafts)
                try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: false)
            }
            return model
        } catch {
            fatalError("Cannot initialize isolated UI acceptance data: \(error)")
        }
    }

    private static func seed(directory: URL, empty: Bool) throws {
        let profile = ConnectionProfile.legacyID
        let foreign = UUID(uuidString: "10000000-0000-0000-0000-000000000099")!
        let projectID = UUID(uuidString: "10000000-0000-0000-0000-000000000010")!
        let documentID = UUID(uuidString: "10000000-0000-0000-0000-000000000011")!
        let currentID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let document = ProjectDocument(id: documentID, title: "nebula document", body: "nebula knowledge body",
                                       createdAt: date, updatedAt: date)
        let project = LocalProject(id: projectID, name: "nebula project", summary: "nebula summary",
                                   instructions: "", createdAt: date, updatedAt: date, knowledgeDocuments: [document])
        let profiles = empty
            ? [ConnectionProfile(id: foreign, name: "Empty installation", serverURL: "", model: "hermes-agent")]
            : [ConnectionProfile(id: profile, name: "Acceptance", serverURL: "https://hermes.invalid/v1",
                                 model: "hermes-agent", localProjects: [project]),
               ConnectionProfile(id: foreign, name: "Other connection", serverURL: "", model: "hermes-agent")]
        let current = Conversation(id: currentID, title: "nebula current",
            messages: [ChatMessage(id: UUID(uuidString: "10000000-0000-0000-0000-000000000021")!,
                                   role: .assistant, content: "nebula original message", createdAt: date)],
            updatedAt: date.addingTimeInterval(10), profileID: profile, projectID: projectID, referenceDocumentIDs: [documentID])
        let archived = Conversation(id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            title: "nebula archived", messages: [], updatedAt: date, profileID: profile, workspace: .init(archived: true))
        let trash = Conversation(id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            title: "nebula trash", messages: [], updatedAt: date, profileID: profile, workspace: .init(trashedAt: date))
        let other = Conversation(id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
            title: "nebula foreign", messages: [], updatedAt: date, profileID: foreign)
        let conversations = empty ? [] : [current, archived, trash, other]
        let selected = empty ? [:] : [profile.uuidString: currentID.uuidString]
        let library = ConnectionLibrary(profiles: profiles, activeID: profiles[0].id, selectedConversations: selected)
        let drafts: [String: String] = empty ? [:] : [
            DraftStore.localKey(profileID: profile, conversationID: currentID): "ORIGINAL-DRAFT",
            DraftStore.localKey(profileID: profile, conversationID: archived.id): "ARCHIVED-DRAFT",
            DraftStore.localKey(profileID: profile, conversationID: nil): "NEW-DRAFT"
        ]
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        try JSONEncoder().encode(conversations).write(to: directory.appendingPathComponent("conversations.json"), options: .atomic)
        try JSONEncoder().encode(drafts).write(to: directory.appendingPathComponent("drafts.json"), options: .atomic)
    }
}

private struct AcceptanceCredentials: CredentialStore {
    func read(account: String) -> String { "" }
    func save(_ key: String, account: String) throws {}
}

private final class AcceptanceDenyNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
#endif
