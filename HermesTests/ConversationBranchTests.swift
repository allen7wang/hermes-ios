import XCTest
import UIKit
@testable import Hermes

final class ConversationBranchTests: XCTestCase {
    override func tearDown() {
        BranchURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testBranchClonesPrefixPreservesOriginalAndDraftsAcrossRelaunchWithoutSending() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let original = try XCTUnwrap(model.selectedConversation)
        model.draft = "原对话未发送的草稿"
        XCTAssertTrue(model.branchConversation(at: original.messages[1].id))
        let branch = try XCTUnwrap(model.selectedConversation)
        XCTAssertNotEqual(branch.id, original.id)
        XCTAssertEqual(branch.messages.map(\.content), ["第一问", "第一答"])
        XCTAssertTrue(Set(branch.messages.map(\.id)).isDisjoint(with: original.messages.map(\.id)))
        XCTAssertEqual(branch.messages.map(\.createdAt), original.messages.prefix(2).map(\.createdAt))
        XCTAssertEqual(branch.profileID, model.activeProfileID)
        XCTAssertFalse(branch.isPinned)
        XCTAssertEqual(model.conversations.first { $0.id == original.id }, original)
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.draft, "")
        model.draft = "分支草稿"
        let reopened = fixture.model()
        XCTAssertEqual(reopened.selectedID, branch.id)
        XCTAssertEqual(reopened.draft, "分支草稿")
        reopened.select(original.id)
        XCTAssertEqual(reopened.draft, "原对话未发送的草稿")
        XCTAssertEqual(reopened.selectedConversation, original)
    }

    @MainActor
    func testSharedImageSurvivesOriginalDeletionAndBranchBackupRestore() throws {
        let fixture = try makeFixture(withImage: true)
        let model = fixture.model()
        let original = try XCTUnwrap(model.selectedConversation)
        let imageID = try XCTUnwrap(original.messages[2].imageID)
        XCTAssertTrue(model.branchConversation(at: original.messages[2].id))
        let branchID = try XCTUnwrap(model.selectedID)
        XCTAssertEqual(try model.makeBackup().images.count, 1)
        model.delete(original.id)
        XCTAssertNotNil(ImageAttachmentStore.image(imageID, directory: model.attachmentDirectory))
        let archive = try BackupArchive.decode(model.makeBackup().encoded())
        let destination = try makeFixture(empty: true).model()
        _ = try destination.importBackup(archive)
        let imported = try XCTUnwrap(destination.profiles.first { $0.id != destination.activeProfileID })
        destination.selectProfile(imported.id)
        XCTAssertEqual(destination.conversations.count, 1)
        XCTAssertEqual(destination.selectedConversation?.messages.map(\.content), ["第一问", "第一答", "旧问题"])
        let restoredImage = try XCTUnwrap(destination.selectedConversation?.messages.last?.imageID)
        XCTAssertNotNil(ImageAttachmentStore.image(restoredImage, directory: destination.attachmentDirectory))
        model.delete(branchID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAttachmentStore.fileURL(for: imageID, directory: model.attachmentDirectory).path))
    }

    @MainActor
    func testEditResendsOnlyEarlierContextAndReplacementWithImageToActiveConnection() async throws {
        let fixture = try makeFixture(withImage: true)
        let model = fixture.model()
        let original = try XCTUnwrap(model.selectedConversation)
        model.draft = "保留这段草稿"
        let received = expectation(description: "edited request")
        BranchURLProtocol.handler = { request in
            XCTAssertEqual(request.request.url?.path, "/p/work/v1/chat/completions")
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer branch-fixture")
            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "selected-agent")
            let messages = body["messages"] as! [[String: Any]]
            XCTAssertEqual(messages.count, 3)
            XCTAssertEqual(messages[0]["content"] as? String, "第一问")
            XCTAssertEqual(messages[1]["content"] as? String, "第一答")
            let parts = messages[2]["content"] as! [[String: Any]]
            XCTAssertEqual(parts[0]["text"] as? String, "新的问题")
            XCTAssertEqual(parts[1]["type"] as? String, "image_url")
            request.respond()
            received.fulfill()
        }
        XCTAssertTrue(model.editAndResend(original.messages[2].id, content: " 新的问题 \n", keepImage: true))
        await fulfillment(of: [received], timeout: 3)
        await finish(model)
        XCTAssertEqual(model.selectedConversation?.messages.map(\.content), ["第一问", "第一答", "新的问题", "新回复"])
        XCTAssertEqual(model.selectedConversation?.messages[2].imageID, original.messages[2].imageID)
        XCTAssertEqual(model.conversations.first { $0.id == original.id }, original)
        model.select(original.id)
        XCTAssertEqual(model.draft, "保留这段草稿")
    }

    @MainActor
    func testInvalidTargetRoleEmptyReplacementAndForeignProfileCannotCreateBranch() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let original = try XCTUnwrap(model.selectedConversation)
        XCTAssertFalse(model.branchConversation(at: UUID()))
        XCTAssertFalse(model.editAndResend(original.messages[1].id, content: "变更", keepImage: false))
        XCTAssertFalse(model.editAndResend(original.messages[2].id, content: " \n ", keepImage: false))
        XCTAssertEqual(model.conversations.count, 1)
        let originalProfile = model.activeProfileID
        _ = try model.saveProfile(id: nil, name: "其他服务器", connection: ConnectionSettings(serverURL: "https://other.test", model: "other", apiKey: "fixture"))
        XCTAssertFalse(model.branchConversation(at: original.messages[0].id))
        XCTAssertFalse(model.editAndResend(original.messages[2].id, content: "不应发送", keepImage: false))
        XCTAssertTrue(model.conversations.isEmpty)
        model.selectProfile(originalProfile)
        XCTAssertEqual(model.selectedConversation, original)
    }

    @MainActor
    func testSaveFailureLeavesSelectionHistoryAndDraftUntouchedWithoutRequest() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let original = try XCTUnwrap(model.selectedConversation)
        model.draft = "保存失败也保留"
        let url = fixture.directory.appendingPathComponent("conversations.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        BranchURLProtocol.handler = { _ in XCTFail("Must not send before saving the branch") }
        XCTAssertFalse(model.branchConversation(at: original.messages[0].id))
        XCTAssertFalse(model.editAndResend(original.messages[2].id, content: "新问题", keepImage: false))
        XCTAssertEqual(model.selectedConversation, original)
        XCTAssertEqual(model.conversations.count, 1)
        XCTAssertEqual(model.draft, "保存失败也保留")
        XCTAssertFalse(model.isSending)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testMissingImageBlocksResendButRemovingItAllowsTextOnlyReplacement() async throws {
        let fixture = try makeFixture(withImage: true)
        let model = fixture.model()
        let original = try XCTUnwrap(model.selectedConversation)
        ImageAttachmentStore.remove(try XCTUnwrap(original.messages[2].imageID), directory: model.attachmentDirectory)
        XCTAssertFalse(model.editAndResend(original.messages[2].id, content: "新问题", keepImage: true))
        XCTAssertEqual(model.conversations.count, 1)
        let received = expectation(description: "text-only replacement")
        BranchURLProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            XCTAssertEqual(messages.last?["content"] as? String, "新问题")
            request.respond(); received.fulfill()
        }
        model.errorMessage = nil
        XCTAssertTrue(model.editAndResend(original.messages[2].id, content: "新问题", keepImage: false))
        await fulfillment(of: [received], timeout: 3)
        await finish(model)
        XCTAssertNil(model.selectedConversation?.messages[2].imageID)
    }

    @MainActor
    func testUnconfiguredConnectionCannotEditAndSendButCanCreateOfflineBranch() throws {
        let fixture = try makeFixture()
        fixture.keys.values = [:]
        let model = fixture.model()
        let original = try XCTUnwrap(model.selectedConversation)
        XCTAssertFalse(model.editAndResend(original.messages[2].id, content: "新问题", keepImage: false))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.conversations.count, 1)
        XCTAssertTrue(model.branchConversation(at: original.messages[0].id))
        XCTAssertFalse(model.isSending)
    }

    @MainActor
    func testGenerationInProgressBlocksAdditionalBranchesAndEdits() async throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let original = try XCTUnwrap(model.selectedConversation)
        let received = expectation(description: "pending reply")
        var pending: BranchURLProtocol?
        BranchURLProtocol.handler = { pending = $0; received.fulfill() }
        XCTAssertTrue(model.editAndResend(original.messages[2].id, content: "新问题", keepImage: false))
        await fulfillment(of: [received], timeout: 3)
        let lastUser = try XCTUnwrap(model.selectedConversation?.messages.last)
        XCTAssertFalse(model.branchConversation(at: lastUser.id))
        XCTAssertFalse(model.editAndResend(lastUser.id, content: "重复", keepImage: false))
        XCTAssertEqual(model.conversations.count, 2)
        pending?.respond()
        await finish(model)
    }

    @MainActor
    func testFailedReplyKeepsSavedBranchAndRetryUsesItWithoutDuplicatingQuestion() async throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let original = try XCTUnwrap(model.selectedConversation)
        BranchURLProtocol.handler = { $0.respond(status: 503) }
        XCTAssertTrue(model.editAndResend(original.messages[2].id, content: "新问题", keepImage: false))
        await finish(model)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.selectedConversation?.messages.map(\.content), ["第一问", "第一答", "新问题"])
        let branchID = model.selectedID
        model.errorMessage = nil
        BranchURLProtocol.handler = { $0.respond() }
        model.retryLastResponse()
        await finish(model)
        XCTAssertEqual(model.selectedID, branchID)
        XCTAssertEqual(model.conversations.count, 2)
        XCTAssertEqual(model.selectedConversation?.messages.map(\.content), ["第一问", "第一答", "新问题", "新回复"])
        XCTAssertEqual(model.conversations.first { $0.id == original.id }, original)
    }

    @MainActor private func finish(_ model: AppModel) async {
        for _ in 0..<150 where model.isSending { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSending)
    }

    @MainActor private func makeFixture(withImage: Bool = false, empty: Bool = false) throws -> BranchFixture {
        let suite = "HermesBranchTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("https://hermes.test/p/work/v1", forKey: "serverURL")
        defaults.set("selected-agent", forKey: "model")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        var imageID: UUID?
        if withImage {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
                UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }.jpegData(compressionQuality: 0.8)!
            imageID = try ImageAttachmentStore.save(data, directory: directory.appendingPathComponent("Attachments"))
        }
        let messages = [ChatMessage(role: .user, content: "第一问"), ChatMessage(role: .assistant, content: "第一答"),
                        ChatMessage(role: .user, content: "旧问题", imageID: imageID), ChatMessage(role: .assistant, content: "旧回复")]
        let source = Conversation(title: "原对话", messages: messages, updatedAt: Date(), pinned: true)
        try JSONEncoder().encode(empty ? [] : [source]).write(to: directory.appendingPathComponent("conversations.json"))
        let keys = MemoryCredentials(); keys.values["api-server-key"] = "branch-fixture"
        return BranchFixture(defaults: defaults, directory: directory, keys: keys)
    }
}

private struct BranchFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    @MainActor func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BranchURLProtocol.self]
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: configuration)
    }
}

private final class BranchURLProtocol: URLProtocol {
    static var handler: ((BranchURLProtocol) -> Void)?
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
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    func respond(status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let payload = status == 200 ? "data: {\"choices\":[{\"delta\":{\"content\":\"新回复\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n" : "unavailable"
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
