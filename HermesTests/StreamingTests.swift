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
