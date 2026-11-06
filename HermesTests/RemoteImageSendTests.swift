import UIKit
import XCTest
@testable import Hermes

final class RemoteImageSendTests: XCTestCase {
    override func tearDown() {
        RemoteImageURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    func testImageOnlySendIncludesImagePart() async throws {
        RemoteImageURLProtocol.streamChunks = Self.completedStream(sessionID: "api_img", content: "收到图片")
        RemoteImageURLProtocol.messagePage = Data(#"{"session_id":"api_img","data":[{"id":"m1","role":"user","content":"[screenshot]"}],"pagination":{"limit":100,"offset":0,"returned":1}}"#.utf8)
        let model = try makeModel(sessionID: "api_img")
        model.attachImage(try Self.sampleJPEG())
        XCTAssertNotNil(model.pendingImage)
        XCTAssertTrue(model.send(""))
        await Self.waitUntil { !model.isSending }
        XCTAssertNil(model.pendingImage)
        XCTAssertNil(model.transientImage)
        let body = try XCTUnwrap(RemoteImageURLProtocol.streamBodies.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let parts = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["type"] as? String, "image_url")
    }

    @MainActor
    func testBlankSendWithoutImageIsRejected() throws {
        let model = try makeModel(sessionID: "api_none")
        XCTAssertFalse(model.send("   "))
        XCTAssertFalse(model.isSending)
    }

    @MainActor
    func testFailedSendRestoresDraftAndImageWhenTurnIsMissing() async throws {
        RemoteImageURLProtocol.streamStatus = 500
        RemoteImageURLProtocol.messagePage = Data(#"{"session_id":"api_fail","data":[{"id":"old","role":"user","content":"旧消息"}],"pagination":{"limit":100,"offset":0,"returned":1}}"#.utf8)
        let model = try makeModel(sessionID: "api_fail")
        model.draft = "看这张图"
        model.attachImage(try Self.sampleJPEG())
        let image = try XCTUnwrap(model.pendingImage)
        XCTAssertTrue(model.send(model.draft))
        await Self.waitUntil { !model.isSending }
        XCTAssertEqual(model.draft, "看这张图")
        XCTAssertEqual(model.pendingImage, image)
        XCTAssertNil(model.transientImage)
    }

    @MainActor
    func testFailedSendDoesNotRestoreImageAfterScreenshotIsStored() async throws {
        RemoteImageURLProtocol.streamStatus = 500
        RemoteImageURLProtocol.messagePage = Data(#"{"session_id":"api_saved","data":[{"id":"new","role":"user","content":"看这张图\n[screenshot]"}],"pagination":{"limit":100,"offset":0,"returned":1}}"#.utf8)
        let model = try makeModel(sessionID: "api_saved")
        model.draft = "看这张图"
        model.attachImage(try Self.sampleJPEG())
        XCTAssertTrue(model.send(model.draft))
        await Self.waitUntil { !model.isSending }
        XCTAssertEqual(model.draft, "")
        XCTAssertNil(model.pendingImage)
    }

    @MainActor
    func testTextSavedWithoutScreenshotRestoresOnlyImage() async throws {
        RemoteImageURLProtocol.streamStatus = 500
        RemoteImageURLProtocol.messagePage = Data(#"{"session_id":"api_text","data":[{"id":"new","role":"user","content":"看这张图"}],"pagination":{"limit":100,"offset":0,"returned":1}}"#.utf8)
        let model = try makeModel(sessionID: "api_text")
        model.draft = "看这张图"
        model.attachImage(try Self.sampleJPEG())
        let image = try XCTUnwrap(model.pendingImage)
        XCTAssertTrue(model.send(model.draft))
        await Self.waitUntil { !model.isSending }
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.pendingImage, image)
    }

    @MainActor
    func testAttachImageRejectsInvalidData() throws {
        let model = try makeModel(sessionID: "api_bad")
        model.attachImage(Data("not an image".utf8))
        XCTAssertNil(model.pendingImage)
        XCTAssertEqual(model.errorMessage, ImageAttachmentStore.ImageError.invalidImage.localizedDescription)
    }

    @MainActor
    private func makeModel(sessionID: String) throws -> RemoteConversationModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteImageURLProtocol.self]
        let session = try JSONDecoder().decode(RemoteSession.self, from: Data("{\"id\":\"\(sessionID)\"}".utf8))
        return RemoteConversationModel(
            session: session,
            client: HermesClient(
                settings: ConnectionSettings(
                    serverURL: "https://hermes.test/v1",
                    model: "hermes-agent",
                    apiKey: ["test", "key"].joined(separator: "-")
                ),
                sessionConfiguration: configuration
            )
        )
    }

    private static func completedStream(sessionID: String, content: String) -> [String] {
        [
            "event: run.started\ndata: {\"run_id\":\"run_1\",\"session_id\":\"\(sessionID)\"}\n\n",
            "event: assistant.completed\ndata: {\"content\":\"\(content)\",\"session_id\":\"\(sessionID)\"}\n\n",
            "event: run.completed\ndata: {\"session_id\":\"\(sessionID)\",\"completed\":true,\"partial\":false}\n\n",
        ]
    }

    private static func sampleJPEG() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for send")
    }
}

private final class RemoteImageURLProtocol: URLProtocol {
    static var streamStatus = 200
    static var streamChunks: [String] = []
    static var streamBodies: [Data] = []
    static var messagePage = Data("{}".utf8)

    static func reset() {
        streamStatus = 200
        streamChunks = []
        streamBodies = []
        messagePage = Data("{}".utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isStream = request.url?.path.contains("chat/stream") == true
        if isStream {
            if let data = request.httpBody {
                Self.streamBodies.append(data)
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
                Self.streamBodies.append(data)
            }
        }
        let status = isStream ? Self.streamStatus : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": isStream && status < 300 ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isStream, status < 300 {
            for chunk in Self.streamChunks {
                client?.urlProtocol(self, didLoad: Data(chunk.utf8))
            }
        } else if !isStream {
            client?.urlProtocol(self, didLoad: Self.messagePage)
        } else {
            client?.urlProtocol(self, didLoad: Data("{\"error\":\"rejected\"}".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
