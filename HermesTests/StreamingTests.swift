import XCTest
@testable import Hermes

final class StreamingTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.chunks = []
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.body = nil
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

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        let body = try XCTUnwrap(MockURLProtocol.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["text"] as? String, "描述图片")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: String])
        XCTAssertEqual(imageURL["url"], "data:image/jpeg;base64,/9j/2Q==")
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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
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
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks {
            client?.urlProtocol(self, didLoad: Data(chunk.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
