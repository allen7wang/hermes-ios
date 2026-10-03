import XCTest
@testable import Hermes

final class ConnectionTests: XCTestCase {
    @MainActor
    func testLegacySettingsKeyAndHistoryMigrateWithoutPlaintextCredentials() throws {
        let fixture = try makeFixture()
        fixture.defaults.set("https://legacy.test/v1", forKey: "serverURL")
        fixture.defaults.set("personal-agent", forKey: "model")
        fixture.keys.values["api-server-key"] = "legacy-secret"
        let old = Conversation(title: "旧版记录", messages: [ChatMessage(role: .user, content: "你好")], updatedAt: Date())
        try JSONEncoder().encode([old]).write(to: fixture.directory.appendingPathComponent("conversations.json"))
        let model = fixture.model()
        XCTAssertEqual(model.settings.serverURL, "https://legacy.test/v1")
        XCTAssertEqual(model.settings.model, "personal-agent")
        XCTAssertEqual(model.settings.apiKey, "legacy-secret")
        XCTAssertEqual(model.selectedID, old.id)
        XCTAssertEqual(model.conversations.first?.profileID, ConnectionProfile.legacyID)
        let stored = try XCTUnwrap(fixture.defaults.data(forKey: "connectionLibrary"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("legacy-secret"))
        let relaunched = fixture.model()
        XCTAssertEqual(relaunched.profiles.count, 1)
        XCTAssertEqual(relaunched.conversations.map(\.id), [old.id])
        XCTAssertEqual(relaunched.settings.apiKey, "legacy-secret")
    }

    @MainActor
    func testProfilesIsolateHistoryAndDraftsAcrossRelaunch() throws {
        let fixture = try makeFixture()
        let first = Conversation(title: "家中记录", messages: [], updatedAt: Date())
        try JSONEncoder().encode([first]).write(to: fixture.directory.appendingPathComponent("conversations.json"))
        let model = fixture.model()
        let home = try model.saveProfile(id: model.activeProfileID, name: "家中", connection: settings("home.test", key: "home-key"))
        model.draft = "家中会话草稿"
        model.newConversation()
        model.draft = "家中新对话草稿"
        let work = try model.saveProfile(id: nil, name: "工作", connection: settings("work.test", key: "work-key"))
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertEqual(model.draft, "")
        model.draft = "工作草稿"
        model.select(first.id) // IDs belonging to a different profile cannot become selected.
        XCTAssertNil(model.selectedID)
        let relaunched = fixture.model()
        XCTAssertEqual(relaunched.activeProfileID, work)
        XCTAssertEqual(relaunched.draft, "工作草稿")
        relaunched.selectProfile(home)
        XCTAssertEqual(relaunched.settings.apiKey, "home-key")
        XCTAssertEqual(relaunched.conversations.map(\.id), [first.id])
        XCTAssertNil(relaunched.selectedID)
        XCTAssertEqual(relaunched.draft, "家中新对话草稿")
        relaunched.select(first.id)
        XCTAssertEqual(relaunched.draft, "家中会话草稿")
        relaunched.selectProfile(work)
        XCTAssertEqual(relaunched.settings.apiKey, "work-key")
        XCTAssertEqual(relaunched.draft, "工作草稿")
    }

    @MainActor
    func testEndpointChangeCreatesIndependentConnectionButEquivalentURLDoesNot() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let home = try model.saveProfile(id: model.activeProfileID, name: "家中", connection: settings("home.test"))
        model.draft = "只属于家中"
        let equivalent = try model.saveProfile(id: home, name: "家中 Mac", connection: ConnectionSettings(
            serverURL: "https://HOME.test:443/v1/", model: "custom-name", apiKey: "rotated-key"))
        XCTAssertEqual(equivalent, home)
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(model.draft, "只属于家中")
        let changed = try model.saveProfile(id: home, name: "另一台", connection: settings("another.test"))
        XCTAssertNotEqual(changed, home)
        XCTAssertEqual(model.profiles.count, 2)
        XCTAssertEqual(model.draft, "")
        model.selectProfile(home)
        XCTAssertEqual(model.settings.model, "custom-name")
        XCTAssertEqual(model.settings.apiKey, "rotated-key")
        XCTAssertEqual(model.draft, "只属于家中")
        let routed = try model.saveProfile(id: home, name: "另一个服务端 Profile", connection: ConnectionSettings(
            serverURL: "https://home.test/p/work/v1", model: "work", apiKey: "key"))
        XCTAssertNotEqual(routed, home)
    }

    @MainActor
    func testDeletingProfileRemovesOnlyItsKeysHistoryAndLocalAndRemoteDrafts() throws {
        let fixture = try makeFixture()
        let old = Conversation(title: "待删除", messages: [], updatedAt: Date())
        try JSONEncoder().encode([old]).write(to: fixture.directory.appendingPathComponent("conversations.json"))
        let model = fixture.model()
        let home = try model.saveProfile(id: model.activeProfileID, name: "家中", connection: settings("home.test"))
        let homeAccount = model.profiles[0].credentialAccount
        model.draft = "本机草稿"
        let remoteKey = DraftStore.remoteKey(settings: model.settings, sessionID: "same-session")
        try model.draftStore.set("远端草稿", for: remoteKey)
        let work = try model.saveProfile(id: nil, name: "工作", connection: settings("work.test", key: "work-secret"))
        model.draft = "保留这个"
        try model.removeProfile(home)
        XCTAssertNil(fixture.keys.values[homeAccount])
        XCTAssertEqual(model.draftStore.text(for: remoteKey), "")
        XCTAssertEqual(model.activeProfileID, work)
        XCTAssertEqual(model.draft, "保留这个")
        let reloaded = fixture.model()
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertTrue(reloaded.conversations.isEmpty)
        XCTAssertEqual(reloaded.settings.apiKey, "work-secret")
        try reloaded.removeProfile(work)
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertFalse(reloaded.settings.isConfigured)
        XCTAssertTrue(reloaded.conversations.isEmpty)
        XCTAssertEqual(reloaded.draft, "")
    }

    @MainActor
    func testCredentialSaveFailureLeavesActiveProfileAndDraftUnchanged() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let before = model.activeProfileID
        model.draft = "待发送内容"
        fixture.keys.failWrites = true
        XCTAssertThrowsError(try model.saveProfile(id: nil, name: "不能保存", connection: settings("other.test")))
        XCTAssertEqual(model.activeProfileID, before)
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(model.draft, "待发送内容")
    }

    @MainActor
    func testStaleConnectionTestCannotChangeNewProfileStatus() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        _ = try model.saveProfile(id: model.activeProfileID, name: "相同服务 A", connection: settings("same.test"))
        let oldSettings = model.settings
        _ = try model.saveProfile(id: nil, name: "相同服务 B", connection: settings("same.test"))
        model.recordConnectionTest(success: true, settings: oldSettings)
        XCTAssertEqual(model.connectionState, .checking)
        model.recordConnectionTest(success: true, settings: model.settings)
        XCTAssertEqual(model.connectionState, .connected)
    }

    @MainActor
    func testUnreadableHistoryIsPreservedInsteadOfOverwrittenDuringMigration() throws {
        let fixture = try makeFixture()
        let url = fixture.directory.appendingPathComponent("conversations.json")
        let original = Data("not valid JSON".utf8)
        try original.write(to: url)
        let model = fixture.model()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.send("不能覆盖原记录"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testUnreadableConnectionAndDraftStoresArePreserved() throws {
        let fixture = try makeFixture()
        let original = Data("broken storage".utf8)
        fixture.defaults.set(original, forKey: "connectionLibrary")
        let model = fixture.model()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertThrowsError(try model.saveProfile(id: nil, name: "不能覆盖", connection: settings("home.test")))
        XCTAssertEqual(fixture.defaults.data(forKey: "connectionLibrary"), original)
        let draftsURL = fixture.directory.appendingPathComponent("drafts.json")
        try original.write(to: draftsURL)
        let drafts = DraftStore(directory: fixture.directory)
        XCTAssertThrowsError(try drafts.set("新草稿", for: "new"))
        XCTAssertEqual(try Data(contentsOf: draftsURL), original)
    }

    func testEndpointValidationRejectsPublicHTTPDisguisedAsPrivateIP() throws {
        for address in ["http://10.example.com", "http://192.168.1.2.evil.test", "http://10.999.2.3"] {
            let client = HermesClient(settings: ConnectionSettings(serverURL: address, model: "hermes-agent", apiKey: "key"))
            XCTAssertThrowsError(try client.rootURL)
        }
        let local = HermesClient(settings: ConnectionSettings(serverURL: "http://192.168.1.4:8642/p/work/v1/", model: "work", apiKey: "key"))
        XCTAssertEqual(try local.rootURL.absoluteString, "http://192.168.1.4:8642/p/work")
    }

    @MainActor
    private func makeFixture() throws -> ConnectionFixture {
        let suite = "HermesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return ConnectionFixture(defaults: defaults, directory: directory, keys: MemoryCredentials())
    }

    private func settings(_ host: String, key: String = "test-key") -> ConnectionSettings {
        ConnectionSettings(serverURL: "https://\(host)/v1", model: "hermes-agent", apiKey: key)
    }
}

private struct ConnectionFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    @MainActor func model() -> AppModel { AppModel(defaults: defaults, directory: directory, credentials: keys) }
}

final class MemoryCredentials: CredentialStore {
    var values: [String: String] = [:]
    var failWrites = false
    func read(account: String) -> String { values[account] ?? "" }
    func save(_ key: String, account: String) throws {
        if failWrites { throw NSError(domain: "HermesTests.Keychain", code: 1) }
        values[account] = key.isEmpty ? nil : key
    }
}
