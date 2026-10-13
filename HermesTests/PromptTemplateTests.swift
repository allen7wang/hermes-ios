import XCTest
@testable import Hermes

final class PromptTemplateTests: XCTestCase {
    func testLegacyConnectionDecodesWithoutTemplates() throws {
        let old = Data("{\"id\":\"\(UUID())\",\"name\":\"旧连接\",\"serverURL\":\"\",\"model\":\"hermes-agent\"}".utf8)
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: old)
        XCTAssertTrue(profile.templates.isEmpty)
        XCTAssertNil(profile.promptTemplates)
    }

    func testBuiltInsAreValidUniqueAndFillable() throws {
        XCTAssertEqual(Set(PromptTemplate.builtIns.map(\.id)).count, 5)
        for template in PromptTemplate.builtIns {
            try template.validate()
            let names = try PromptRendering.variables(in: template.body)
            let values = Dictionary(uniqueKeysWithValues: names.map { ($0, "测试值：" + $0) })
            let rendered = try PromptRendering.render(template.body, values: values)
            XCTAssertFalse(rendered.contains("{{"))
            for name in names { XCTAssertTrue(rendered.contains("测试值：" + name)) }
        }
    }

    func testVariablesAreOrderedDeduplicatedAndSupportChineseNames() throws {
        XCTAssertEqual(try PromptRendering.variables(in: "{{ 主题 }} / {{code_2}} / {{主题}} / {{Café}}"), ["主题", "code_2", "Café"])
        XCTAssertEqual(try PromptRendering.variables(in: "{普通单括号} 👩🏽‍💻"), [])
    }

    func testMalformedAndExcessiveVariablesAreRejected() throws {
        for body in ["{{}}", "{{ }}", "{{名字", "名字}}", "{{a b}}", "{{a-b}}", "{{a\nb}}", "{{{{a}}", "{{" + String(repeating: "字", count: 41) + "}}"] {
            XCTAssertThrowsError(try PromptRendering.variables(in: body), body)
        }
        let body = (0...20).map { "{{v\($0)}}" }.joined()
        XCTAssertThrowsError(try PromptRendering.variables(in: body))
        XCTAssertNoThrow(try PromptRendering.variables(in: (0..<20).map { "{{v\($0)}}" }.joined()))
    }

    func testValuesAreLiteralAndPreserveUnicodeLineBreaksAndRepeatedReferences() throws {
        let value = "  👩🏽‍💻\n{\"json\":{}}\n{{another}}  "
        XCTAssertEqual(try PromptRendering.render("前{{代码}}中{{代码}}后", values: ["代码": value, "another": "不能递归替换"]), "前" + value + "中" + value + "后")
    }

    func testMissingValuesAndOutputLimitsRejectWithoutTruncation() throws {
        XCTAssertThrowsError(try PromptRendering.render("{{主题}}", values: [:]))
        XCTAssertThrowsError(try PromptRendering.render("{{主题}}", values: ["主题": " \n "]))
        XCTAssertThrowsError(try PromptRendering.render("{{主题}}", values: ["主题": String(repeating: "字", count: 10_001)]))
        let body = String(repeating: "{{主题}}", count: 6)
        XCTAssertThrowsError(try PromptRendering.render(body, values: ["主题": String(repeating: "字", count: 10_000)]))
        XCTAssertEqual(try PromptRendering.render(String(repeating: "{{主题}}", count: 5), values: ["主题": String(repeating: "字", count: 10_000)]).count, 50_000)
        XCTAssertThrowsError(try PromptRendering.render(String(repeating: "x", count: 10_001), values: [:]))
    }

    func testSearchAndPinnedSorting() {
        let old = PromptTemplate(title: "Café", body: "正文", updatedAt: Date(timeIntervalSince1970: 1), pinned: true)
        let new = PromptTemplate(title: "工作", body: "RELEASE CHECKLIST", updatedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(PromptTemplate.filtered([new, old], query: "").map(\.id), [old.id, new.id])
        XCTAssertEqual(PromptTemplate.filtered([new, old], query: " cafe ").map(\.id), [old.id])
        XCTAssertEqual(PromptTemplate.filtered([new, old], query: "release").map(\.id), [new.id])
    }

    func testDraftModesAndBounds() throws {
        XCTAssertEqual(try PromptRendering.draft(current: "已有", rendered: "新增", mode: .append), "已有\n\n新增")
        XCTAssertEqual(try PromptRendering.draft(current: "已有", rendered: "新增", mode: .replace), "新增")
        XCTAssertEqual(try PromptRendering.draft(current: "", rendered: "新增", mode: .append), "新增")
        XCTAssertThrowsError(try PromptRendering.draft(current: "", rendered: " \n ", mode: .append))
        XCTAssertThrowsError(try PromptRendering.draft(current: String(repeating: "字", count: 100_000), rendered: "新增", mode: .append))
        XCTAssertEqual(try PromptRendering.draft(current: String(repeating: "字", count: 100_000), rendered: "新增", mode: .replace), "新增")
    }

    @MainActor func testCreateEditPinPersistWithoutChangingDraftHistoryOrCredentials() throws {
        let fixture = try fixture(); let model = fixture.model()
        model.draft = "原草稿"
        let id = try model.savePromptTemplate(id: nil, title: "  周报  ", body: " 请整理 {{内容}} ", profileID: model.activeProfileID)
        let created = try XCTUnwrap(model.promptTemplates.first)
        try model.togglePromptPin(id, profileID: model.activeProfileID)
        try model.savePromptTemplate(id: id, title: "新版周报", body: "{{内容}}", profileID: model.activeProfileID)
        let reopened = fixture.model()
        XCTAssertEqual(reopened.promptTemplates.first?.title, "新版周报")
        XCTAssertEqual(reopened.promptTemplates.first?.createdAt, created.createdAt)
        XCTAssertEqual(reopened.promptTemplates.first?.pinned, true)
        XCTAssertEqual(reopened.draft, "原草稿")
        XCTAssertTrue(reopened.conversations.isEmpty)
        XCTAssertEqual(reopened.settings.apiKey, "prompt-test-key")
        XCTAssertFalse(String(decoding: try Data(contentsOf: fixture.directory.appendingPathComponent("connections.json")), as: UTF8.self).contains("prompt-test-key"))
        try reopened.deletePromptTemplate(id, profileID: reopened.activeProfileID)
        XCTAssertTrue(fixture.model().promptTemplates.isEmpty)
    }

    @MainActor func testTemplatesStayWithConnectionAcrossEquivalentAndChangedEndpoints() throws {
        let fixture = try fixture(); let model = fixture.model()
        let home = model.activeProfileID
        let id = try model.savePromptTemplate(id: nil, title: "家中模板", body: "模板正文", profileID: home)
        let equivalent = try model.saveProfile(id: home, name: "家中改名", connection: ConnectionSettings(serverURL: "https://HERMES.test:443/v1/", model: "new", apiKey: "rotated"))
        XCTAssertEqual(equivalent, home)
        XCTAssertEqual(model.promptTemplates.map(\.id), [id])
        let work = try model.saveProfile(id: home, name: "工作", connection: ConnectionSettings(serverURL: "https://work.test", model: "hermes-agent", apiKey: "work"))
        XCTAssertNotEqual(work, home)
        XCTAssertTrue(model.promptTemplates.isEmpty)
        XCTAssertThrowsError(try model.deletePromptTemplate(id, profileID: home))
        model.selectProfile(home)
        XCTAssertEqual(model.promptTemplates.map(\.id), [id])
        try model.removeProfile(home)
        XCTAssertTrue(model.promptTemplates.isEmpty)
        XCTAssertEqual(model.profiles.count, 1)
    }

    @MainActor func testTemplateWriteFailurePreservesPublishedStateAndCache() throws {
        let fixture = try fixture(); let model = fixture.model()
        let id = try model.savePromptTemplate(id: nil, title: "保留", body: "原文", profileID: model.activeProfileID)
        let before = model.profiles
        let cache = fixture.defaults.data(forKey: "connectionLibrary")
        let url = fixture.directory.appendingPathComponent("connections.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.togglePromptPin(id, profileID: model.activeProfileID))
        XCTAssertThrowsError(try model.deletePromptTemplate(id, profileID: model.activeProfileID))
        XCTAssertThrowsError(try model.savePromptTemplate(id: id, title: "不能更新", body: "新文", profileID: model.activeProfileID))
        XCTAssertEqual(model.profiles, before)
        XCTAssertEqual(fixture.defaults.data(forKey: "connectionLibrary"), cache)
    }

    @MainActor func testUnreadableAndInvalidTemplateStoresArePreserved() throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "损坏", serverURL: "", model: "hermes-agent", promptTemplates: [PromptTemplate(title: "模板", body: "{{缺失结束")])
        let data = try JSONEncoder().encode(ConnectionLibrary(profiles: [profile], activeID: profile.id))
        let url = fixture.directory.appendingPathComponent("connections.json")
        try data.write(to: url)
        let model = fixture.model()
        XCTAssertTrue(model.needsRecovery)
        XCTAssertThrowsError(try model.savePromptTemplate(id: nil, title: "新模板", body: "内容", profileID: profile.id))
        XCTAssertThrowsError(try model.applyPrompt("新文", mode: .replace, expectedDraftKey: model.draftKey))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor func testApplyingPromptPreservesSelectionAndDraftThenSurvivesRelaunchWithoutSending() throws {
        let fixture = try fixture(); let model = fixture.model()
        model.draft = "已有草稿"
        try model.applyPrompt("套用正文", mode: .append, expectedDraftKey: model.draftKey)
        XCTAssertEqual(model.draft, "已有草稿\n\n套用正文")
        XCTAssertEqual(fixture.model().draft, model.draft)
        XCTAssertNil(model.selectedID)
        XCTAssertFalse(model.isSending)
        XCTAssertTrue(model.conversations.isEmpty)
        try model.applyPrompt("替换正文", mode: .replace, expectedDraftKey: model.draftKey)
        XCTAssertEqual(model.draft, "替换正文")
    }

    @MainActor func testStaleConversationAndConnectionTargetsRejectApply() throws {
        let fixture = try fixture()
        let conversation = Conversation(title: "来源", messages: [], updatedAt: Date())
        try JSONEncoder().encode([conversation]).write(to: fixture.directory.appendingPathComponent("conversations.json"))
        let model = fixture.model(); model.draft = "来源草稿"
        let oldKey = model.draftKey
        model.newConversation(); model.draft = "新对话草稿"
        XCTAssertThrowsError(try model.applyPrompt("不能套用", mode: .replace, expectedDraftKey: oldKey))
        XCTAssertEqual(model.draft, "新对话草稿")
        let currentKey = model.draftKey
        try model.saveProfile(id: nil, name: "工作", connection: ConnectionSettings(serverURL: "https://work.test", model: "hermes-agent", apiKey: "work"))
        model.draft = "工作草稿"
        XCTAssertThrowsError(try model.applyPrompt("不能套用", mode: .append, expectedDraftKey: currentKey))
        XCTAssertEqual(model.draft, "工作草稿")
    }

    @MainActor func testLocalDraftSaveFailureAndOverflowLeavePreviousText() throws {
        let fixture = try fixture(); let model = fixture.model()
        model.draft = String(repeating: "字", count: 100_000)
        XCTAssertThrowsError(try model.applyPrompt("溢出", mode: .append, expectedDraftKey: model.draftKey))
        XCTAssertEqual(model.draft.count, 100_000)
        model.draft = "原草稿"
        let url = fixture.directory.appendingPathComponent("drafts.json")
        try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.applyPrompt("新文", mode: .replace, expectedDraftKey: model.draftKey))
        XCTAssertEqual(model.draft, "原草稿")
    }

    @MainActor func testBackupVersionsAndForeignTemplateImportAreIdempotentAndPreserveEdits() throws {
        let source = try fixture(); let model = source.model()
        XCTAssertEqual(try model.makeBackup().version, 1)
        let id = try model.savePromptTemplate(id: nil, title: "源模板", body: "{{主题}}", profileID: model.activeProfileID)
        try model.togglePromptPin(id, profileID: model.activeProfileID)
        let backup = try BackupArchive.decode(model.makeBackup().encoded())
        XCTAssertEqual(backup.version, 3); XCTAssertEqual(backup.templateCount, 1)
        let target = try fixture(); let imported = target.model()
        let report = try imported.importBackup(backup)
        XCTAssertEqual(report.templatesAdded, 1)
        let profile = try XCTUnwrap(imported.profiles.first { !$0.templates.isEmpty })
        XCTAssertNotEqual(profile.templates.first?.id, id)
        imported.selectProfile(profile.id)
        let mappedID = try XCTUnwrap(imported.promptTemplates.first?.id)
        try imported.savePromptTemplate(id: mappedID, title: "本机修改", body: "新正文", profileID: profile.id)
        let second = try imported.importBackup(backup)
        XCTAssertEqual(second.templatesAdded, 0)
        XCTAssertEqual(imported.promptTemplates.first?.title, "本机修改")
        XCTAssertEqual(imported.promptTemplates.first?.pinned, true)
        XCTAssertEqual(target.model().promptTemplates.first?.title, "本机修改")
    }

    @MainActor func testSameInstallationImportAddsMissingTemplatesAndKeepsExistingEdits() throws {
        let fixture = try fixture(); let model = fixture.model()
        let id = try model.savePromptTemplate(id: nil, title: "已有", body: "正文", profileID: model.activeProfileID)
        var archive = try model.makeBackup()
        archive.profiles[0].templates.append(PromptTemplate(title: "新增", body: "新正文"))
        try model.savePromptTemplate(id: id, title: "本机改名", body: "改后正文", profileID: model.activeProfileID)
        XCTAssertEqual(try model.importBackup(archive).templatesAdded, 1)
        XCTAssertEqual(model.promptTemplates.count, 2)
        XCTAssertEqual(model.promptTemplates.first { $0.id == id }?.title, "本机改名")
        XCTAssertEqual(try model.importBackup(archive).templatesAdded, 0)
    }

    @MainActor func testBackupRejectsDowngradedDuplicateAndMalformedTemplates() throws {
        let fixture = try fixture(); let model = fixture.model()
        try model.savePromptTemplate(id: nil, title: "模板", body: "{{主题}}", profileID: model.activeProfileID)
        let valid = try model.makeBackup()
        for version in [1, 2] { var invalid = valid; invalid.version = version; XCTAssertThrowsError(try invalid.encoded()) }
        var duplicate = valid; duplicate.profiles[0].templates.append(duplicate.profiles[0].templates[0])
        XCTAssertThrowsError(try duplicate.encoded())
        var malformed = valid; malformed.profiles[0].templates[0].body = "{{未闭合"
        XCTAssertThrowsError(try malformed.encoded())
        var excessive = valid; excessive.profiles[0].templates = (0...100).map { PromptTemplate(title: "模板\($0)", body: "正文") }
        XCTAssertThrowsError(try excessive.encoded())
    }

    @MainActor func testMergeOverTemplateLimitIsRejectedBeforeAnyWrites() throws {
        let fixture = try fixture(); let model = fixture.model()
        var archive = try model.makeBackup(); archive.version = 3
        let existing = (0..<100).map { PromptTemplate(title: "模板\($0)", body: "正文") }
        archive.profiles[0].templates = existing
        try model.importBackup(archive)
        archive.profiles[0].templates = [PromptTemplate(title: "第101个", body: "正文")]
        let before = try Data(contentsOf: fixture.directory.appendingPathComponent("connections.json"))
        XCTAssertThrowsError(try model.importBackup(archive))
        XCTAssertEqual(model.promptTemplates.count, 100)
        XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("connections.json")), before)
    }

    @MainActor func testInterruptedBackupRecoveryRetainsTemplateMetadataAndCredentials() throws {
        let fixture = try fixture(); let model = fixture.model()
        try model.savePromptTemplate(id: nil, title: "恢复模板", body: "{{主题}}", profileID: model.activeProfileID)
        let backup = try model.makeBackup()
        let merge = try BackupMerge.prepare(backup, installationID: backup.installationID,
            library: ConnectionLibrary(profiles: model.profiles.map { profile in var copy = profile; copy.templates = []; return copy }, activeID: model.activeProfileID), conversations: [], drafts: [:])
        try JSONEncoder().encode(merge.state).write(to: fixture.directory.appendingPathComponent("pending-restore.json"))
        let reopened = fixture.model()
        XCTAssertEqual(reopened.promptTemplates.first?.title, "恢复模板")
        XCTAssertEqual(reopened.settings.apiKey, "prompt-test-key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("pending-restore.json").path))
    }

    @MainActor func testRemotePromptChangesOnlyRemoteDraftWithoutSendingAndSurvivesRelaunch() throws {
        let fixture = try fixture(); let model = fixture.model(); model.draft = "本机草稿"
        let session = try JSONDecoder().decode(RemoteSession.self, from: Data(#"{"id":"template-session","title":"测试会话"}"#.utf8))
        let client = HermesClient(settings: model.settings)
        let remote = RemoteConversationModel(session: session, client: client, draftStore: model.draftStore)
        remote.draft = "远端原草稿"
        try remote.applyPrompt("套用正文", mode: .append)
        XCTAssertEqual(remote.draft, "远端原草稿\n\n套用正文")
        XCTAssertEqual(model.draft, "本机草稿")
        XCTAssertFalse(remote.isSending); XCTAssertTrue(remote.messages.isEmpty)
        let reopened = RemoteConversationModel(session: session, client: client, draftStore: DraftStore(directory: fixture.directory))
        XCTAssertEqual(reopened.draft, remote.draft)
        try reopened.applyPrompt("替换正文", mode: .replace)
        XCTAssertEqual(reopened.draft, "替换正文")
        let unavailable = RemoteConversationModel(session: session, client: client)
        XCTAssertThrowsError(try unavailable.applyPrompt("不能丢失", mode: .replace))
    }

    @MainActor func testRemoteDraftWriteFailurePreservesPreviousText() throws {
        let fixture = try fixture(); let model = fixture.model()
        let session = try JSONDecoder().decode(RemoteSession.self, from: Data(#"{"id":"remote"}"#.utf8))
        let remote = RemoteConversationModel(session: session, client: HermesClient(settings: model.settings), draftStore: model.draftStore)
        remote.draft = "原远端草稿"
        let url = fixture.directory.appendingPathComponent("drafts.json")
        try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try remote.applyPrompt("替换正文", mode: .replace))
        XCTAssertEqual(remote.draft, "原远端草稿")
    }

    @MainActor private func fixture() throws -> PromptFixture {
        let suite = "HermesPromptTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("https://hermes.test/v1", forKey: "serverURL")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys = MemoryCredentials(); keys.values["api-server-key"] = "prompt-test-key"
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return PromptFixture(defaults: defaults, directory: directory, keys: keys)
    }
}

private struct PromptFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    @MainActor func model() -> AppModel { AppModel(defaults: defaults, directory: directory, credentials: keys) }
}
