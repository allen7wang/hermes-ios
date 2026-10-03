import XCTest
@testable import Hermes

final class StreamingTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.chunks = []
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.body = nil
        MockURLProtocol.responseData = nil
        MockURLProtocol.statusCode = 200
        super.tearDown()
    }

    func testSSEParserHandlesKeepaliveNamedEventsAndMultipleDataLines() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(": keepalive"))
        XCTAssertNil(parser.consume(""))
        XCTAssertNil(parser.consume("event: hermes.tool.progress"))
        XCTAssertNil(parser.consume("data: {\"status\":\"running\","))
        XCTAssertNil(parser.consume("data: \"tool\":\"terminal\"}"))
        XCTAssertEqual(
            parser.consume(""),
            SSEFrame(
                event: "hermes.tool.progress",
                data: "{\"status\":\"running\",\n\"tool\":\"terminal\"}"
            )
        )
        XCTAssertNil(parser.consume("data: [DONE]"))
        XCTAssertEqual(parser.consume(""), SSEFrame(event: nil, data: "[DONE]"))
    }

    func testOldChatMessageDecodesWithoutImageField() throws {
        struct LegacyMessage: Encodable {
            let id = UUID()
            let role = "user"
            let content = "旧对话"
            let createdAt = Date(timeIntervalSinceReferenceDate: 42)
        }

        let encoded = try JSONEncoder().encode(LegacyMessage())
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoded)
        XCTAssertEqual(decoded.content, "旧对话")
        XCTAssertNil(decoded.imageID)
    }

    func testClientStreamsTextAndToolProgress() async throws {
        MockURLProtocol.chunks = [
            ": keepalive\n\n",
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n",
            "event: hermes.tool.progress\ndata: {\"tool\":\"terminal\",\"emoji\":\"🖥️\",\"label\":\"运行命令\",\"status\":\"running\"}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"你\"},\"finish_reason\":null}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":null}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n"
        ]
        let client = makeClient()
        var deltas = ""
        var toolNames: [String] = []
        let reply = try await client.stream(
            messages: [ChatMessage(role: .user, content: "你好")]
        ) { event in
            switch event {
            case .delta(let value): deltas += value
            case .tool(let progress): toolNames.append(progress.tool ?? "")
            }
        }
        XCTAssertEqual(reply, "你好")
        XCTAssertEqual(deltas, "你好")
        XCTAssertEqual(toolNames, ["terminal"])

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Hermes-Session-Id"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(MockURLProtocol.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testImageMessageUsesInlineImagePart() async throws {
        MockURLProtocol.chunks = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"看到了\"},\"finish_reason\":null}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n"
        ]
        let imageID = try ImageAttachmentStore.save(Data([0xFF, 0xD8, 0xFF, 0xD9]))
        defer { ImageAttachmentStore.remove(imageID) }
        let message = ChatMessage(role: .user, content: "描述图片", imageID: imageID)
        _ = try await makeClient().stream(messages: [message]) { _ in }

        let body = try XCTUnwrap(MockURLProtocol.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["text"] as? String, "描述图片")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: String])
        XCTAssertEqual(imageURL["url"], "data:image/jpeg;base64,/9j/2Q==")
    }

    func testRemoteSessionListAndTranscript() async throws {
        MockURLProtocol.responseData = Data("""
        {"object":"list","data":[{"id":"api_123","title":"项目讨论","source":"api_server","message_count":2,"last_active":1720000000.0}],"limit":50,"offset":0,"has_more":false}
        """.utf8)
        let client = makeClient()
        let page = try await client.sessions()
        XCTAssertEqual(page.data.first?.displayTitle, "项目讨论")
        XCTAssertEqual(page.data.first?.messageCount, 2)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/sessions")
        let query = URLComponents(url: try XCTUnwrap(MockURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "include_children" })?.value, "true")

        MockURLProtocol.responseData = Data("""
        {"object":"list","session_id":"api_123","data":[{"id":1,"role":"user","content":"看这张 data:image/png;base64,AAAA 图片"},{"id":2,"role":"assistant","content":"已看到"}],"pagination":{"limit":100,"offset":0,"order":"latest","returned":2}}
        """.utf8)
        let messages = try await client.sessionMessages("api_123")
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages[0].content, "看这张 [图片] 图片")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/sessions/api_123/messages")
    }

    func testRemoteSessionRenameAndDelete() async throws {
        MockURLProtocol.responseData = Data("""
        {"object":"hermes.session","session":{"id":"api_123","title":"新标题"}}
        """.utf8)
        let client = makeClient()
        let session = try await client.renameSession("api_123", title: "新标题")
        XCTAssertEqual(session.displayTitle, "新标题")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PATCH")
        let body = try XCTUnwrap(MockURLProtocol.body)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: String])?["title"], "新标题")

        MockURLProtocol.responseData = Data(#"{"object":"hermes.session.deleted","id":"api_123","deleted":true}"#.utf8)
        try await client.deleteSession("api_123")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
    }

    func testJobsIncludePausedAndToggle() async throws {
        MockURLProtocol.responseData = Data("""
        {"jobs":[{"id":"abcdef123456","name":"每日报告","schedule_display":"每天 9 点","enabled":false,"state":"paused","next_run_at":null}]}
        """.utf8)
        let client = makeClient()
        let jobs = try await client.jobs()
        XCTAssertEqual(jobs.first?.name, "每日报告")
        XCTAssertEqual(jobs.first?.isPaused, true)
        let query = URLComponents(url: try XCTUnwrap(MockURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "include_disabled" })?.value, "true")

        MockURLProtocol.responseData = Data("""
        {"job":{"id":"abcdef123456","name":"每日报告","enabled":true,"state":"scheduled"}}
        """.utf8)
        let updated = try await client.setJobPaused("abcdef123456", paused: false)
        XCTAssertFalse(updated.isPaused)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/jobs/abcdef123456/resume")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")

        MockURLProtocol.responseData = Data("""
        {"job":{"id":"fedcba654321","name":"巡检","enabled":true,"state":"scheduled"}}
        """.utf8)
        let created = try await client.createJob(name: "巡检", schedule: "every 1h", prompt: "检查服务")
        XCTAssertEqual(created.name, "巡检")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/jobs")
        let body = try XCTUnwrap(MockURLProtocol.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["schedule"], "every 1h")
        XCTAssertEqual(json["deliver"], "local")
    }

    func testSessionStreamUsesServerHistoryAndFinalAnswer() async throws {
        MockURLProtocol.chunks = [
            ": keepalive\n\n",
            "event: run.started\ndata: {\"run_id\":\"run_1\",\"session_id\":\"api_123\"}\n\n",
            "event: assistant.delta\ndata: {\"delta\":\"正在分析\"}\n\n",
            "event: assistant.commentary\ndata: {\"text\":\"检查项目\",\"already_streamed\":false}\n\n",
            "event: tool.started\ndata: {\"tool_name\":\"terminal\"}\n\n",
            "event: approval.request\ndata: {\"run_id\":\"run_1\",\"request_id\":\"approve_1\",\"command\":\"example\",\"choices\":[\"once\",\"deny\"]}\n\n",
            "event: assistant.completed\ndata: {\"content\":\"最终回答\",\"session_id\":\"api_compacted\"}\n\n",
            "event: run.completed\ndata: {\"session_id\":\"api_compacted\",\"completed\":true,\"partial\":false}\n\n"
        ]
        var startedID: String?
        var approvalID: String?
        var streamed = ""
        let result = try await makeClient().streamSession("api_123", input: "继续") { event in
            switch event {
            case .started(let id): startedID = id
            case .delta(let delta): streamed += delta
            case .approval(let approval): approvalID = approval.requestID
            default: break
            }
        }
        XCTAssertEqual(result.content, "最终回答")
        XCTAssertEqual(result.sessionID, "api_compacted")
        XCTAssertEqual(streamed, "正在分析")
        XCTAssertEqual(startedID, "run_1")
        XCTAssertEqual(approvalID, "approve_1")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/sessions/api_123/chat/stream")
        let body = try XCTUnwrap(MockURLProtocol.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["input": "继续"])
    }

    func testSessionStreamRejectsPartialAndMissingTerminalStatus() throws {
        var decoder = SessionStreamDecoder(sessionID: "api_123")
        _ = try decoder.consume(SSEFrame(event: "assistant.completed", data: #"{"content":"未完成的答案"}"#))
        XCTAssertThrowsError(try decoder.consume(SSEFrame(event: "run.completed", data: #"{"completed":false,"partial":true,"turn_exit_reason":"iteration_limit"}"#)))
        XCTAssertNil(decoder.result)
        var disconnected = SessionStreamDecoder(sessionID: "api_123")
        _ = try disconnected.consume(SSEFrame(event: "assistant.delta", data: #"{"delta":"部分内容"}"#))
        XCTAssertThrowsError(try disconnected.consume(SSEFrame(event: "done", data: "{}")))
    }

    @MainActor
    func testOlderMessagesArePrependedWithoutDuplicates() async throws {
        let session = try JSONDecoder().decode(RemoteSession.self, from: Data(#"{"id":"api_123"}"#.utf8))
        let model = RemoteConversationModel(session: session, client: makeClient())
        MockURLProtocol.responseData = Data("""
        {"session_id":"api_123","data":[{"id":3,"role":"user","content":"较新"},{"id":4,"role":"assistant","content":"最新"}],"pagination":{"limit":2,"offset":0,"returned":2}}
        """.utf8)
        await model.reload()
        XCTAssertTrue(model.hasOlderMessages)
        MockURLProtocol.responseData = Data("""
        {"session_id":"api_123","data":[{"id":2,"role":"user","content":"更早"},{"id":3,"role":"user","content":"较新"}],"pagination":{"limit":2,"offset":2,"returned":2}}
        """.utf8)
        await model.loadOlder()
        XCTAssertEqual(model.messages.map(\.id), ["2", "3", "4"])
        let query = URLComponents(url: try XCTUnwrap(MockURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "offset" })?.value, "2")
        XCTAssertEqual(query?.first(where: { $0.name == "include_compacted" })?.value, "true")
    }

    func testJobEditingPreservesScheduleAndOtherFields() async throws {
        MockURLProtocol.responseData = Data("""
        {"job":{"id":"abcdef123456","name":"改名后","schedule":{"kind":"once","run_at":"2030-01-01T09:00:00+08:00"},"schedule_display":"once at 2030-01-01 09:00","enabled":false,"state":"paused"}}
        """.utf8)
        let client = makeClient()
        let updated = try await client.updateJob("abcdef123456", fields: ["name": "改名后"])
        XCTAssertEqual(updated.editableSchedule, "2030-01-01T09:00:00+08:00")
        XCTAssertTrue(updated.isPaused)
        let body = try XCTUnwrap(MockURLProtocol.body)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body), ["name": "改名后"])
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PATCH")
        MockURLProtocol.responseData = Data(#"{"ok":true}"#.utf8)
        try await client.deleteJob("abcdef123456")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
    }

    func testApprovalAndStopTargetTheExactRun() async throws {
        let approval = try JSONDecoder().decode(RemoteApproval.self, from: Data(#"{"run_id":"run_1","request_id":"approval_2","choices":["once","deny"]}"#.utf8))
        MockURLProtocol.responseData = Data(#"{"resolved":1}"#.utf8)
        let client = makeClient()
        try await client.resolveApproval(approval, choice: "deny")
        let body = try XCTUnwrap(MockURLProtocol.body)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body), ["choice": "deny", "request_id": "approval_2"])
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/v1/runs/run_1/approval")
        MockURLProtocol.responseData = Data(#"{"status":"stopping"}"#.utf8)
        try await client.stopRun("run_1")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/v1/runs/run_1/stop")
    }

    func testModelDiscoveryDeduplicatesAliasesAndPreservesProfileRoute() async throws {
        MockURLProtocol.responseData = Data(#"{"data":[{"id":"work"},{"id":""},{"id":"work"},{"id":"custom"}]}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = HermesClient(settings: ConnectionSettings(serverURL: "https://hermes.test/p/work/v1", model: "custom", apiKey: "profile-key"), sessionConfiguration: configuration)
        let models = try await client.availableModels()
        XCTAssertEqual(models, ["work", "custom"])
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/p/work/v1/models")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer profile-key")
    }

    @MainActor
    func testSendingClearsOnlySubmittedDraftAndLocksConnectionChanges() async throws {
        let suite = "HermesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let model = AppModel(defaults: defaults, directory: directory, credentials: MemoryCredentials(), sessionConfiguration: configuration)
        let home = model.activeProfileID
        let work = try model.saveProfile(id: nil, name: "工作", connection: makeClient().settings)
        model.draft = "工作草稿"
        model.selectProfile(home)
        model.draft = "未配置时保留"
        XCTAssertFalse(model.send(model.draft))
        XCTAssertEqual(model.draft, "未配置时保留")
        _ = try model.saveProfile(id: home, name: "家中", connection: makeClient().settings)
        let sentKey = model.draftKey
        MockURLProtocol.chunks = ["data: {\"choices\":[{\"delta\":{\"content\":\"回复\"},\"finish_reason\":null}]}\n\n", "data: [DONE]\n\n"]
        XCTAssertTrue(model.send(model.draft))
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.draftStore.text(for: sentKey), "")
        model.selectProfile(work)
        XCTAssertEqual(model.activeProfileID, home)
        XCTAssertThrowsError(try model.removeProfile(work))
        XCTAssertThrowsError(try model.saveProfile(id: work, name: "不能修改", connection: makeClient().settings))
        // Wait for the mocked network stream with a bounded deadline.
        for _ in 0..<200 where model.isSending { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.selectedConversation?.messages.last?.content, "回复")
        model.selectProfile(work)
        XCTAssertEqual(model.draft, "工作草稿")
        XCTAssertTrue(model.conversations.isEmpty)
    }

    @MainActor
    func testRemoteDraftsSurviveReopenAndFollowCompactedSessionID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HermesDraftTests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftStore(directory: directory)
        let session = try JSONDecoder().decode(RemoteSession.self, from: Data(#"{"id":"old-session"}"#.utf8))
        var settings = makeClient().settings
        settings.profileID = UUID()
        let client = HermesClient(settings: settings, sessionConfiguration: makeClient().sessionConfiguration)
        let model = RemoteConversationModel(session: session, client: client, draftStore: store)
        model.draft = "稍后继续的内容"
        let reopenedStore = DraftStore(directory: directory)
        let reopened = RemoteConversationModel(session: session, client: client, draftStore: reopenedStore)
        XCTAssertEqual(reopened.draft, "稍后继续的内容")
        settings.profileID = UUID()
        let other = RemoteConversationModel(session: session, client: HermesClient(settings: settings), draftStore: store)
        XCTAssertEqual(other.draft, "")
        MockURLProtocol.responseData = Data(#"{"session_id":"new-session","data":[]}"#.utf8)
        await reopened.reload()
        XCTAssertEqual(reopenedStore.text(for: DraftStore.remoteKey(settings: client.settings, sessionID: "old-session")), "")
        XCTAssertEqual(reopenedStore.text(for: DraftStore.remoteKey(settings: client.settings, sessionID: "new-session")), "稍后继续的内容")
        reopened.draft = "更新后的草稿"
        let compacted = try JSONDecoder().decode(RemoteSession.self, from: Data(#"{"id":"new-session"}"#.utf8))
        let latest = RemoteConversationModel(session: compacted, client: client, draftStore: DraftStore(directory: directory))
        XCTAssertEqual(latest.draft, "更新后的草稿")
    }

    private func makeClient() -> HermesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return HermesClient(
            settings: ConnectionSettings(
                serverURL: "https://hermes.test/v1",
                model: "hermes-agent",
                apiKey: "test-key"
            ),
            sessionConfiguration: configuration
        )
    }
}

private final class MockURLProtocol: URLProtocol {
    static var chunks: [String] = []
    static var lastRequest: URLRequest?
    static var body: Data?
    static var responseData: Data?
    static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.body = nil
        if let data = request.httpBody {
            Self.body = data
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            Self.body = data
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": Self.responseData == nil ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = Self.responseData {
            client?.urlProtocol(self, didLoad: data)
        } else {
            for chunk in Self.chunks {
                client?.urlProtocol(self, didLoad: Data(chunk.utf8))
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
