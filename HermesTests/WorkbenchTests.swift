import XCTest
@testable import Hermes

final class WorkbenchTests: XCTestCase {
    override func tearDown() { WorkbenchProtocol.handler = nil; super.tearDown() }

    func testLegacyConversationAndProfileDecodeWithEmptyWorkspace() throws {
        let id = UUID()
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data("{\"id\":\"\(id)\",\"title\":\"旧记录\",\"messages\":[],\"updatedAt\":0}".utf8))
        XCTAssertNil(conversation.workspace); XCTAssertFalse(conversation.isArchived)
        XCTAssertTrue(conversation.workspaceState.configuration.isDefault)
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data("{\"id\":\"\(id)\",\"name\":\"旧连接\",\"serverURL\":\"\",\"model\":\"hermes-agent\"}".utf8))
        XCTAssertNil(profile.conversationDefaults)
    }

    func testTagsNormalizeUnicodeCaseAndWhitespaceAndEnforceLimits() throws {
        XCTAssertEqual(try ConversationWorkspace.normalizedTags(" 工作，Swift、 swift, Café, cafe \n学习"), ["工作", "Swift", "Café", "学习"])
        XCTAssertThrowsError(try ConversationWorkspace.normalizedTags(String(repeating: "字", count: 21)))
        XCTAssertThrowsError(try ConversationWorkspace.normalizedTags((0...8).map { "标签\($0)" }))
        XCTAssertThrowsError(try ConversationWorkspace(tags: [" Work "]).validate())
    }

    func testConfigurationValidationAndNormalization() throws {
        XCTAssertEqual(try ConversationConfiguration(model: " model ", provider: " provider ", systemPrompt: " 指令\n", contextTurns: 50).validated(),
                       ConversationConfiguration(model: "model", provider: "provider", systemPrompt: "指令", contextTurns: 50))
        for invalid in [ConversationConfiguration(provider: "provider"), .init(model: "m", provider: "bad provider"),
                        .init(model: "a\nb"), .init(systemPrompt: String(repeating: "x", count: 10_001)),
                        .init(contextTurns: -1), .init(contextTurns: 51)] {
            XCTAssertThrowsError(try invalid.validated())
        }
    }

    func testContextLimitRetainsWholeTurnsAndLatestQuestionWithoutEditingHistory() {
        let history = [message(.assistant, "孤立回复"), message(.user, "一"), message(.assistant, "一答"),
                       message(.user, "二"), message(.assistant, "二答"), message(.user, "三")]
        XCTAssertEqual(ConversationConfiguration(contextTurns: 2).history(from: history).map(\.content), ["二", "二答", "三"])
        XCTAssertEqual(ConversationConfiguration(contextTurns: 1).history(from: history).map(\.content), ["三"])
        XCTAssertEqual(ConversationConfiguration().history(from: history), history)
        XCTAssertEqual(ConversationConfiguration(contextTurns: 20).history(from: history), Array(history.dropFirst()))
    }

    func testSearchTagsArchiveScopeAndSorting() {
        let first = Conversation(title: "Café 工作", messages: [message(.user, "周报")], updatedAt: Date(timeIntervalSince1970: 1), pinned: true,
                                 workspace: .init(tags: ["研究"]))
        let second = Conversation(title: "Beta", messages: [], updatedAt: Date(timeIntervalSince1970: 2))
        let archived = Conversation(title: "归档", messages: [], updatedAt: Date(), pinned: true, workspace: .init(tags: ["研究"], archived: true))
        let all = [second, archived, first]
        XCTAssertEqual(filter(all).map(\.id), [first.id, second.id])
        XCTAssertEqual(filter(all, scope: .archived).map(\.id), [archived.id])
        XCTAssertEqual(filter(all, scope: .pinned).map(\.id), [first.id])
        XCTAssertEqual(filter(all, query: "cafe").map(\.id), [first.id])
        XCTAssertEqual(filter(all, query: "研究").map(\.id), [first.id])
        XCTAssertEqual(filter(all, tag: "研究").map(\.id), [first.id])
        XCTAssertEqual(filter(all, tag: "不存在"), [])
        XCTAssertEqual(filter(all, sort: .title).map(\.id), [second.id, first.id])
        XCTAssertEqual(filter(all, sort: .oldest).map(\.id), [first.id, second.id])
    }

    func testMarkdownExportKeepsCodeButExcludesNotesAndSystemInstructions() {
        let record = Conversation(title: "工作/记录", messages: [ChatMessage(role: .assistant, content: "```swift\nlet n = 1\n```", imageID: UUID(),
            bookmark: .init(createdAt: Date(), note: "私密备注"))], updatedAt: Date(),
            workspace: .init(tags: ["工作"], configuration: .init(systemPrompt: "私密指令")))
        let text = ConversationWorkbench.markdown([record])
        XCTAssertTrue(text.contains("# 工作/记录")); XCTAssertTrue(text.contains("标签：工作"))
        XCTAssertTrue(text.contains("```swift\nlet n = 1\n```")); XCTAssertTrue(text.contains("[图片："))
        XCTAssertFalse(text.contains("私密"))
        XCTAssertEqual(ConversationWorkbench.filename("../工作/记录:\n"), "-工作-记录--")
        XCTAssertEqual(ConversationWorkbench.filename("..."), "Hermes-对话")
        XCTAssertTrue(ConversationWorkbench.markdown([record, record]).contains("\n\n---\n\n"))
    }

    @MainActor func testSettingsPersistWithoutChangingHistoryDraftOrRecency() throws {
        let fixture = try fixture(); let model = fixture.model()
        let source = try XCTUnwrap(model.selectedConversation); model.draft = "保留草稿"
        let config = ConversationConfiguration(model: "work-model", provider: "custom", systemPrompt: "简洁", contextTurns: 6)
        try save(model, title: "新标题", tags: "工作，Swift,swift", config: config)
        let reopened = fixture.model()
        XCTAssertEqual(reopened.selectedConversation?.workspaceState.tags, ["工作", "Swift"])
        XCTAssertEqual(reopened.conversationConfiguration, config)
        XCTAssertEqual(reopened.selectedConversation?.title, "新标题")
        XCTAssertEqual(reopened.selectedConversation?.messages, source.messages)
        XCTAssertEqual(reopened.selectedConversation?.updatedAt, source.updatedAt)
        XCTAssertEqual(reopened.draft, "保留草稿")
    }

    @MainActor func testStaleSettingsCannotTargetAnotherConversationOrProfile() throws {
        let fixture = try fixture(); let model = fixture.model(); let key = model.draftKey
        model.newConversation()
        XCTAssertThrowsError(try model.saveConversationSettings(title: "错误目标", tags: "", configuration: .init(),
            expectedDraftKey: key, profileID: model.activeProfileID))
        XCTAssertThrowsError(try model.saveConversationSettings(title: "", tags: "", configuration: .init(),
            expectedDraftKey: model.draftKey, profileID: UUID()))
    }

    @MainActor func testDefaultsPersistStayScopedAndDoNotChangeExistingConversations() throws {
        let fixture = try fixture(); let model = fixture.model(); let original = model.activeProfileID
        model.newConversation()
        let config = ConversationConfiguration(systemPrompt: "新对话指令", contextTurns: 8)
        try save(model, config: config)
        XCTAssertEqual(fixture.model().conversationConfiguration, config)
        model.select(model.conversations[0].id)
        XCTAssertTrue(model.conversationConfiguration.isDefault)
        _ = try model.saveProfile(id: original, name: "已改名", connection: model.settings)
        model.newConversation()
        XCTAssertEqual(model.conversationConfiguration, config)
        _ = try model.saveProfile(id: original, name: "新服务器", connection: .init(serverURL: "https://other.test", model: "agent", apiKey: "key"))
        XCTAssertTrue(model.conversationConfiguration.isDefault)
        model.selectProfile(original); model.newConversation()
        XCTAssertEqual(model.conversationConfiguration, config)
    }

    @MainActor func testArchivePreservesDraftBookmarksAndRecencyAndBlocksSending() throws {
        let fixture = try fixture(); let model = fixture.model(); let source = try XCTUnwrap(model.selectedConversation)
        model.draft = "归档保留"
        try model.setArchived([source.id], archived: true)
        let reopened = fixture.model()
        XCTAssertTrue(try XCTUnwrap(reopened.selectedConversation).isArchived)
        XCTAssertEqual(reopened.draft, "归档保留")
        XCTAssertEqual(reopened.selectedConversation?.messages, source.messages)
        XCTAssertEqual(reopened.selectedConversation?.updatedAt, source.updatedAt)
        XCTAssertFalse(reopened.send("不应发送")); reopened.retryLastResponse(); XCTAssertFalse(reopened.isSending)
        try reopened.setArchived([source.id], archived: false)
        XCTAssertFalse(try XCTUnwrap(fixture.model().selectedConversation).isArchived)
    }

    @MainActor func testBulkActionsRejectUnknownOrForeignIDsWithoutPartialWrites() throws {
        let fixture = try fixture(); let model = fixture.model(); let before = model.conversations
        let ids = Set(before.map(\.id))
        XCTAssertThrowsError(try model.setArchived(ids.union([UUID()]), archived: true))
        XCTAssertThrowsError(try model.deleteConversations(ids.union([UUID()])))
        XCTAssertEqual(model.conversations, before)
        let original = model.activeProfileID
        _ = try model.saveProfile(id: nil, name: "其他", connection: .init(serverURL: "https://other.test", model: "m", apiKey: "key"))
        XCTAssertThrowsError(try model.setArchived(ids, archived: true))
        XCTAssertThrowsError(try model.deleteConversations(ids))
        model.selectProfile(original); XCTAssertEqual(model.conversations, before)
    }

    @MainActor func testBulkDeleteCleansTargetDraftsAndPreservesNewComposer() throws {
        let fixture = try fixture(); let model = fixture.model(); let first = try XCTUnwrap(model.selectedID)
        model.draft = "删除草稿"
        let other = try XCTUnwrap(model.conversations.first { $0.id != first }?.id)
        model.select(other); model.draft = "保留草稿"
        model.newConversation(); model.draft = "新对话草稿"
        try model.deleteConversations([first])
        XCTAssertNil(model.selectedID); XCTAssertEqual(model.draft, "新对话草稿")
        XCTAssertNil(try model.draftStore.snapshot()[DraftStore.localKey(profileID: model.activeProfileID, conversationID: first)])
        model.select(other); XCTAssertEqual(model.draft, "保留草稿")
        try model.deleteConversations([other])
        XCTAssertTrue(model.conversations.isEmpty); XCTAssertNil(model.selectedID)
        XCTAssertEqual(fixture.model().draft, "新对话草稿")
    }

    @MainActor func testFailedWriteDoesNotPublishArchiveSettingsOrSendAndKeepsDraft() throws {
        let fixture = try fixture(); let model = fixture.model(); let before = model.conversations
        model.draft = "失败保留"
        let url = fixture.directory.appendingPathComponent("conversations.json")
        try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.setArchived(Set(before.map(\.id)), archived: true))
        XCTAssertThrowsError(try save(model, title: "不会保存", tags: "标签", config: .init(systemPrompt: "指令")))
        XCTAssertFalse(model.send(model.draft)); XCTAssertEqual(model.conversations, before)
        XCTAssertEqual(model.draft, "失败保留"); XCTAssertFalse(model.isSending)
    }

    @MainActor func testArchivedBranchCopiesConfigurationAndTagsButIsActiveAndUnbookmarked() throws {
        let fixture = try fixture(); let model = fixture.model(); let source = try XCTUnwrap(model.selectedConversation)
        try save(model, tags: "研究", config: .init(systemPrompt: "指令", contextTurns: 2))
        try model.setArchived([source.id], archived: true)
        XCTAssertTrue(model.branchConversation(at: source.messages[0].id))
        let branch = try XCTUnwrap(model.selectedConversation)
        XCTAssertFalse(branch.isArchived); XCTAssertFalse(branch.isPinned); XCTAssertNil(branch.messages[0].bookmark)
        XCTAssertEqual(branch.workspaceState.tags, ["研究"]); XCTAssertEqual(branch.workspaceState.configuration.contextTurns, 2)
        XCTAssertTrue(try XCTUnwrap(model.conversations.first { $0.id == source.id }).isArchived)
    }

    @MainActor func testV4RoundTripAndRepeatedImportPreserveWorkspaceAndDefaults() throws {
        let fixture = try fixture(); let model = fixture.model(); let source = try XCTUnwrap(model.selectedConversation)
        try save(model, tags: "工作", config: .init(systemPrompt: "指令", contextTurns: 4))
        try model.setArchived([source.id], archived: true); model.newConversation()
        try save(model, config: .init(model: "future"))
        let backup = try BackupArchive.decode(model.makeBackup().encoded())
        XCTAssertEqual(backup.version, 4)
        let destination = try self.fixture(empty: true).model()
        XCTAssertEqual(try destination.importBackup(backup).conversationsAdded, 2)
        XCTAssertEqual(try destination.importBackup(backup).conversationsAdded, 0)
        let imported = try XCTUnwrap(destination.profiles.first { $0.id != destination.activeProfileID })
        XCTAssertEqual(imported.conversationDefaults?.model, "future")
        destination.selectProfile(imported.id)
        let restored = try XCTUnwrap(destination.conversations.first { $0.title == source.title })
        XCTAssertTrue(restored.isArchived); XCTAssertEqual(restored.workspaceState.tags, ["工作"])
        XCTAssertEqual(restored.workspaceState.configuration.contextTurns, 4); XCTAssertEqual(restored.messages, source.messages)
    }

    @MainActor func testV4RejectsDowngradeAndInvalidTagsAndLeavesOldExportCompatible() throws {
        let fixture = try fixture(); let model = fixture.model()
        XCTAssertEqual(try model.makeBackup().version, 2)
        try model.setArchived(Set(model.conversations.map(\.id)), archived: true)
        var backup = try model.makeBackup()
        for version in [1, 2, 3] { backup.version = version; XCTAssertThrowsError(try backup.encoded()) }
        backup.version = 4; backup.conversations[0].workspace?.tags = [String(repeating: "字", count: 21)]
        XCTAssertThrowsError(try backup.encoded())
    }

    @MainActor func testV4JournalRecoversWorkspaceAfterInterruptedRestore() throws {
        let fixture = try fixture(); let model = fixture.model()
        try model.setArchived(Set(model.conversations.map(\.id)), archived: true)
        let state = BackupRestoreState(library: .init(profiles: model.profiles, activeID: model.activeProfileID),
            conversations: try model.makeBackup().conversations, drafts: [:], images: [:])
        try JSONEncoder().encode(state).write(to: fixture.directory.appendingPathComponent("pending-restore.json"))
        XCTAssertTrue(fixture.model().conversations.allSatisfy(\.isArchived))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("pending-restore.json").path))
    }

    func testRequestSendsSystemProviderAndBoundedHistoryWithoutLoadingOmittedImage() async throws {
        WorkbenchProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "chosen"); XCTAssertEqual(body["provider"] as? String, "custom")
            let messages = body["messages"] as! [[String: Any]]
            XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["system", "user"])
            XCTAssertEqual(messages[0]["content"] as? String, "用中文"); XCTAssertEqual(messages[1]["content"] as? String, "新问题")
            XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains("秘密备注"))
            request.respond()
        }
        let history = [ChatMessage(role: .user, content: "旧图片", imageID: UUID()), message(.assistant, "旧回复"),
                       ChatMessage(role: .user, content: "新问题", bookmark: .init(createdAt: Date(), note: "秘密备注"))]
        let reply = try await client().stream(messages: history, configuration: .init(model: "chosen", provider: "custom", systemPrompt: "用中文", contextTurns: 1)) { _ in }
        XCTAssertEqual(reply, "完成"); XCTAssertEqual(history.count, 3)
    }

    func testDefaultRequestOmitsProviderAndSystemAndRetainsAllMessages() async throws {
        WorkbenchProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "default-model"); XCTAssertNil(body["provider"])
            let messages = body["messages"] as! [[String: Any]]
            XCTAssertEqual(messages.count, 3); XCTAssertEqual(messages.first?["role"] as? String, "user")
            request.respond()
        }
        _ = try await client().stream(messages: [message(.user, "一"), message(.assistant, "答"), message(.user, "二")]) { _ in }
    }

    @MainActor func testSendCapturesDefaultsAndBlocksWorkspaceMutationsUntilCompletion() async throws {
        let fixture = try fixture(empty: true); let model = fixture.model()
        let config = ConversationConfiguration(model: "chosen", provider: "custom", systemPrompt: "指令", contextTurns: 3)
        try save(model, config: config)
        let received = expectation(description: "request")
        var pending: WorkbenchProtocol?
        WorkbenchProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "chosen")
            pending = request; received.fulfill()
        }
        model.draft = "问题"; XCTAssertTrue(model.send(model.draft))
        await fulfillment(of: [received], timeout: 3)
        let id = try XCTUnwrap(model.selectedID)
        XCTAssertEqual(model.conversationConfiguration, config)
        XCTAssertThrowsError(try model.setArchived([id], archived: true)); XCTAssertThrowsError(try model.deleteConversations([id]))
        XCTAssertThrowsError(try save(model))
        pending?.respond()
        for _ in 0..<150 where model.isSending { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSending); XCTAssertEqual(fixture.model().conversationConfiguration, config)
        XCTAssertEqual(fixture.model().selectedConversation?.messages.last?.content, "完成")
    }

    func testTaskCopyKeepsEditableFieldsAndClearsOldOneShotTime() throws {
        let cron = try job(#"{"id":"a","name":"周报","prompt":"整理周报","schedule":{"kind":"cron","expr":"0 9 * * 1"},"last_error":"不复制"}"#)
        let draft = RemoteJobDraft(copying: cron)
        XCTAssertEqual(draft.name, "周报 · 副本"); XCTAssertEqual(draft.schedule, "0 9 * * 1"); XCTAssertEqual(draft.prompt, "整理周报")
        let once = try job(#"{"id":"b","name":"一次","schedule":{"kind":"once","run_at":"2020-01-01T09:00:00Z"}}"#)
        XCTAssertEqual(RemoteJobDraft(copying: once).schedule, "")
    }

    func testTaskOverviewAndRetryBackoffBoundaries() throws {
        let jobs = try [job(#"{"id":"a","name":"运行","state":"running"}"#),
                        job(#"{"id":"b","name":"暂停失败","state":"paused","last_status":"failed"}"#),
                        job(#"{"id":"c","name":"结束","state":"completed","enabled":false}"#)]
        let summary = RemoteJobOverview(jobs)
        XCTAssertEqual(summary.running, 1); XCTAssertEqual(summary.attention, 1); XCTAssertEqual(summary.paused, 1)
        XCTAssertEqual(RemoteRefreshInterval.off.delay(afterFailures: 2), 0)
        XCTAssertEqual(RemoteRefreshInterval.thirty.delay(afterFailures: 0), 30)
        XCTAssertEqual(RemoteRefreshInterval.thirty.delay(afterFailures: 2), 120)
        XCTAssertEqual(RemoteRefreshInterval.twoMinutes.delay(afterFailures: 100), 300)
    }

    private func filter(_ values: [Conversation], scope: ConversationScope = .active, query: String = "", tag: String? = nil, sort: ConversationSort = .recent) -> [Conversation] {
        ConversationWorkbench.filtered(values, scope: scope, query: query, tag: tag, sort: sort)
    }
    private func message(_ role: ChatMessage.Role, _ text: String) -> ChatMessage { .init(role: role, content: text) }
    private func job(_ text: String) throws -> RemoteJob { try JSONDecoder().decode(RemoteJob.self, from: Data(text.utf8)) }
    private func client() -> HermesClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WorkbenchProtocol.self]
        return HermesClient(settings: .init(serverURL: "https://hermes.test", model: "default-model", apiKey: "fixture-key"), sessionConfiguration: config)
    }
    @MainActor private func save(_ model: AppModel, title: String? = nil, tags: String = "", config: ConversationConfiguration = .init()) throws {
        try model.saveConversationSettings(title: title ?? model.selectedConversation?.title ?? "", tags: tags, configuration: config,
            expectedDraftKey: model.draftKey, profileID: model.activeProfileID)
    }
    @MainActor private func fixture(empty: Bool = false) throws -> WorkbenchFixture {
        let suite = "HermesWorkbenchTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("https://hermes.test", forKey: "serverURL"); defaults.set("default-model", forKey: "model")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let records = [Conversation(title: "第一段", messages: [ChatMessage(role: .user, content: "问题", bookmark: .init(createdAt: Date(), note: "备注"))], updatedAt: Date()),
                       Conversation(title: "第二段", messages: [message(.assistant, "答复")], updatedAt: Date(timeIntervalSince1970: 1))]
        try JSONEncoder().encode(empty ? [] : records).write(to: directory.appendingPathComponent("conversations.json"))
        let keys = MemoryCredentials(); keys.values["api-server-key"] = "fixture-key"
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return WorkbenchFixture(defaults: defaults, directory: directory, keys: keys)
    }
}

private struct WorkbenchFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    @MainActor func model() -> AppModel {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WorkbenchProtocol.self]
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: config)
    }
}

private final class WorkbenchProtocol: URLProtocol {
    static var handler: ((WorkbenchProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    var body: Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }; result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    func respond() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"完成\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
