import XCTest
import UIKit
@testable import Hermes

final class ConversationSafetyTests: XCTestCase {
    override func tearDown() { SafetyProtocol.handler = nil; SafetyProtocol.requests = 0; super.tearDown() }

    func testVersionFourWorkspaceDecodesWithoutTrashField() throws {
        let data = Data(#"{"tags":["工作"],"archived":true,"configuration":{"model":"","provider":"","systemPrompt":"","contextTurns":0}}"#.utf8)
        let workspace = try JSONDecoder().decode(ConversationWorkspace.self, from: data)
        XCTAssertNil(workspace.trashedAt); XCTAssertTrue(workspace.archived)
    }

    @MainActor func testTrashAndRestorePreserveFullRecordDraftImagesAndSelectionAcrossRelaunch() throws {
        let f = try fixture(image: true); let model = f.model()
        let original = try XCTUnwrap(model.selectedConversation)
        model.draft = "仍要保留的草稿"
        try model.deleteConversations([original.id])
        XCTAssertNil(model.selectedID); XCTAssertFalse(model.isSending)
        XCTAssertFalse(model.conversations.contains { $0.id == original.id })
        XCTAssertNil(model.libraryItem(.init(conversationID: original.id, messageID: original.messages[0].id)))
        let reopened = f.model(); let trashed = try XCTUnwrap(reopened.trashedConversations.first)
        XCTAssertEqual(trashed.messages, original.messages); XCTAssertEqual(trashed.updatedAt, original.updatedAt)
        XCTAssertEqual(trashed.workspaceState.tags, original.workspaceState.tags); XCTAssertTrue(trashed.isPinned)
        XCTAssertEqual(try reopened.makeBackup().images.count, 1)
        XCTAssertEqual(try reopened.draftStore.snapshot()[DraftStore.localKey(profileID: reopened.activeProfileID, conversationID: original.id)], "仍要保留的草稿")
        try reopened.restoreConversations([original.id]); reopened.select(original.id)
        XCTAssertEqual(reopened.selectedConversation, original); XCTAssertEqual(reopened.draft, "仍要保留的草稿")
        XCTAssertEqual(f.keys.values["api-server-key"], "safety-fixture-key")
    }

    @MainActor func testRestoringArchivedRecordReturnsToArchiveWithoutChangingRecency() throws {
        let f = try fixture(); let model = f.model(); let id = try XCTUnwrap(model.selectedID)
        try model.setArchived([id], archived: true)
        let original = model.selectedConversation
        try model.deleteConversations([id]); try model.restoreConversations([id])
        XCTAssertEqual(model.conversations.first { $0.id == id }, original)
        XCTAssertTrue(try XCTUnwrap(model.conversations.first { $0.id == id }).isArchived)
    }

    @MainActor func testTrashCanBeRestoredAsBatchAndNeverExpiresOnReopen() throws {
        let f = try fixture(); let model = f.model(); let ids = Set(model.conversations.map(\.id))
        try model.deleteConversations(ids)
        XCTAssertTrue(model.conversations.isEmpty); XCTAssertEqual(f.model().trashedConversations.count, 2)
        try model.restoreConversations(ids)
        XCTAssertEqual(model.conversations.count, 2); XCTAssertTrue(model.trashedConversations.isEmpty)
        XCTAssertEqual(f.model().conversations.count, 2)
    }

    @MainActor func testPermanentDeletionRequiresTrashAndRejectsMixedOrForeignIDsAtomically() throws {
        let f = try fixture(); let model = f.model(); let original = model.activeProfileID
        let id = try XCTUnwrap(model.selectedID)
        XCTAssertThrowsError(try model.permanentlyDeleteConversations([id]))
        try model.deleteConversations([id])
        XCTAssertThrowsError(try model.permanentlyDeleteConversations([id, UUID()]))
        XCTAssertThrowsError(try model.restoreConversations([id, UUID()]))
        XCTAssertEqual(model.trashedConversations.count, 1)
        _ = try model.saveProfile(id: nil, name: "其他", connection: .init(serverURL: "https://other.test", model: "other", apiKey: "key"))
        XCTAssertThrowsError(try model.restoreConversations([id]))
        XCTAssertThrowsError(try model.permanentlyDeleteConversations([id]))
        model.selectProfile(original); XCTAssertEqual(model.trashedConversations.count, 1)
    }

    @MainActor func testPermanentDeletionRetainsImagesReferencedByAnotherTrashRecord() throws {
        let f = try fixture(image: true); let model = f.model(); let ids = model.conversations.map(\.id)
        let imageID = try XCTUnwrap(model.selectedConversation?.messages[0].imageID)
        try model.deleteConversations(Set(ids))
        try model.permanentlyDeleteConversations([ids[0]])
        XCTAssertNotNil(ImageAttachmentStore.image(imageID, directory: model.attachmentDirectory))
        XCTAssertEqual(try model.makeBackup().images.count, 1)
        try model.permanentlyDeleteConversations([ids[1]])
        XCTAssertNil(ImageAttachmentStore.image(imageID, directory: model.attachmentDirectory))
        XCTAssertEqual(try model.makeBackup().images.count, 0)
    }

    @MainActor func testFailedTrashJournalWriteDoesNotPublishOrLoseDrafts() throws {
        let f = try fixture(); let model = f.model(); let before = model.conversations
        model.draft = "失败也保留"
        let drafts = try model.draftStore.snapshot()
        try FileManager.default.createDirectory(at: f.directory.appendingPathComponent("pending-restore.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.deleteConversations(Set(before.map(\.id))))
        XCTAssertEqual(model.conversations, before); XCTAssertTrue(model.trashedConversations.isEmpty)
        XCTAssertEqual(model.draft, "失败也保留"); XCTAssertEqual(try model.draftStore.snapshot(), drafts)
        XCTAssertTrue(model.needsRecovery)
    }

    @MainActor func testFailedRestoreWriteLeavesTrashUntouched() throws {
        let f = try fixture(); let model = f.model(); let id = try XCTUnwrap(model.selectedID)
        try model.deleteConversations([id]); let before = model.trashedConversations
        let file = f.directory.appendingPathComponent("conversations.json")
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.restoreConversations([id]))
        XCTAssertEqual(model.trashedConversations, before); XCTAssertFalse(model.conversations.contains { $0.id == id })
    }

    @MainActor func testBackupV5RoundTripKeepsTrashAndRepeatedImportKeepsLocalRestore() throws {
        let f = try fixture(image: true); let source = f.model(); let id = try XCTUnwrap(source.selectedID)
        source.draft = "随备份恢复的草稿"; try source.deleteConversations([id])
        let backup = try BackupArchive.decode(source.makeBackup().encoded())
        XCTAssertEqual(backup.version, 5); XCTAssertEqual(backup.trashCount, 1)
        let destination = try fixture(empty: true).model()
        _ = try destination.importBackup(backup)
        let imported = try XCTUnwrap(destination.profiles.first { $0.id != destination.activeProfileID })
        destination.selectProfile(imported.id)
        XCTAssertEqual(destination.trashedConversations.count, 1); XCTAssertEqual(destination.conversations.count, 1)
        let restoredID = try XCTUnwrap(destination.trashedConversations.first?.id)
        try destination.restoreConversations([restoredID]); destination.select(restoredID)
        XCTAssertEqual(destination.draft, "随备份恢复的草稿")
        XCTAssertEqual(try destination.importBackup(backup).conversationsAdded, 0)
        XCTAssertTrue(destination.trashedConversations.isEmpty)
        XCTAssertEqual(destination.conversations.count, 2)
    }

    @MainActor func testTrashBackupRejectsDowngradeAndRestoredDataExportsLowerFormat() throws {
        let f = try fixture(); let model = f.model(); let id = try XCTUnwrap(model.selectedID)
        XCTAssertEqual(try model.makeBackup().version, 4)
        try model.deleteConversations([id])
        var archive = try model.makeBackup()
        for version in 1...4 { archive.version = version; XCTAssertThrowsError(try archive.encoded()) }
        try model.restoreConversations([id]); XCTAssertEqual(try model.makeBackup().version, 4)
    }

    @MainActor func testInterruptedTrashJournalRecoversRecordAndDraftWithoutResurrection() throws {
        let f = try fixture(); let model = f.model(); let id = try XCTUnwrap(model.selectedID)
        model.draft = "保留原文"; try model.deleteConversations([id])
        let archive = try model.makeBackup()
        let savedLibrary = try JSONDecoder().decode(ConnectionLibrary.self,
            from: Data(contentsOf: f.directory.appendingPathComponent("connections.json")))
        let state = BackupRestoreState(library: savedLibrary,
            conversations: archive.conversations, drafts: archive.drafts, images: archive.images)
        try JSONEncoder().encode(state).write(to: f.directory.appendingPathComponent("pending-restore.json"))
        let reopened = f.model()
        XCTAssertEqual(reopened.trashedConversations.count, 1); XCTAssertEqual(reopened.conversations.count, 1)
        XCTAssertNil(reopened.selectedID)
        try reopened.restoreConversations([id]); reopened.select(id); XCTAssertEqual(reopened.draft, "保留原文")
    }

    @MainActor func testTrashCannotBeSelectedPinnedOrBookmarkedUntilRestored() throws {
        let f = try fixture(); let model = f.model(); let original = try XCTUnwrap(model.selectedConversation)
        try model.deleteConversations([original.id])
        model.select(original.id); model.togglePin(original.id); model.rename(original.id, to: "错误改名")
        XCTAssertNil(model.selectedID)
        XCTAssertThrowsError(try model.toggleBookmark(.init(conversationID: original.id, messageID: original.messages[0].id)))
        XCTAssertEqual(model.trashedConversations.first?.title, original.title)
        XCTAssertEqual(model.trashedConversations.first?.isPinned, original.isPinned)
    }

    @MainActor func testContextPreviewIsReadOnlyExcludesNotesAndDoesNotSendOrPersistPendingImage() throws {
        let f = try fixture(); let model = f.model()
        model.draft = "  下一问  "
        let records = model.conversations; let drafts = try model.draftStore.snapshot()
        let bytes = try Data(contentsOf: f.directory.appendingPathComponent("conversations.json"))
        let preview = try model.previewNextRequest(model.draft, hasImage: true, expectedDraftKey: model.draftKey)
        XCTAssertEqual(preview.plan.configuration.systemPrompt, "简洁回答")
        XCTAssertEqual(preview.plan.messages.last?.content, "下一问"); XCTAssertEqual(preview.imageCount, 1)
        XCTAssertTrue(preview.plan.messages.allSatisfy { $0.bookmark == nil })
        XCTAssertEqual(preview.historyCount, 2); XCTAssertEqual(preview.plan.omittedMessageCount, 0)
        XCTAssertEqual(model.conversations, records); XCTAssertEqual(try model.draftStore.snapshot(), drafts)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("conversations.json")), bytes)
        XCTAssertEqual(try model.makeBackup().images.count, 0)
        XCTAssertFalse(model.isSending); XCTAssertEqual(SafetyProtocol.requests, 0)
    }

    @MainActor func testPreviewAndActualWireRequestUseSameContextModelProviderAndInput() async throws {
        let f = try fixture(); let model = f.model()
        try model.saveConversationSettings(title: "上下文", tags: "工作", configuration: .init(model: "chosen", provider: "custom", systemPrompt: "用中文", contextTurns: 1),
            expectedDraftKey: model.draftKey, profileID: model.activeProfileID)
        model.draft = " 本次输入 "
        let preview = try model.previewNextRequest(model.draft, hasImage: false, expectedDraftKey: model.draftKey)
        XCTAssertEqual(preview.historyCount, 0); XCTAssertEqual(preview.plan.omittedMessageCount, 2)
        let received = expectation(description: "wire request")
        SafetyProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, preview.effectiveModel)
            XCTAssertEqual(body["provider"] as? String, preview.plan.configuration.provider)
            let messages = body["messages"] as! [[String: Any]]
            XCTAssertEqual(messages.first?["role"] as? String, "system")
            XCTAssertEqual(messages.first?["content"] as? String, preview.plan.configuration.systemPrompt)
            XCTAssertEqual(Array(messages.dropFirst()).compactMap { $0["content"] as? String }, preview.plan.messages.map(\.content))
            XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains("私密备注"))
            request.respond(); received.fulfill()
        }
        XCTAssertTrue(model.send(model.draft)); await fulfillment(of: [received], timeout: 3)
        for _ in 0..<150 where model.isSending { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.selectedConversation?.messages.count, 4)
    }

    @MainActor func testPreviewRejectsStaleArchivedAndEmptyInputAndEnforcesLength() throws {
        let f = try fixture(); let model = f.model(); let id = try XCTUnwrap(model.selectedID)
        XCTAssertThrowsError(try model.previewNextRequest("", hasImage: false, expectedDraftKey: model.draftKey))
        XCTAssertThrowsError(try model.previewNextRequest("x", hasImage: false, expectedDraftKey: "old"))
        XCTAssertThrowsError(try model.previewNextRequest(String(repeating: "字", count: 100_001), hasImage: false, expectedDraftKey: model.draftKey))
        XCTAssertEqual(try model.previewNextRequest("", hasImage: true, expectedDraftKey: model.draftKey).imageCount, 1)
        try model.setArchived([id], archived: true)
        XCTAssertThrowsError(try model.previewNextRequest("问题", hasImage: false, expectedDraftKey: model.draftKey))
    }

    @MainActor func testOversizedSendDoesNotSaveOrClearDraftOrStartNetwork() throws {
        let model = try fixture().model(); let records = model.conversations
        model.draft = "保留"
        XCTAssertFalse(model.send(String(repeating: "字", count: 100_001)))
        XCTAssertEqual(model.conversations, records); XCTAssertEqual(model.draft, "保留")
        XCTAssertEqual(SafetyProtocol.requests, 0); XCTAssertFalse(model.isSending)
    }

    func testLibraryFiltersScopeTagsRolesAndBookmarksAndAlwaysExcludesTrash() {
        let active = Conversation(title: "工作", messages: [ChatMessage(role: .user, content: "问题"), ChatMessage(role: .assistant, content: "答案", bookmark: .init(createdAt: Date(), note: "参考"))],
            updatedAt: Date(), workspace: .init(tags: ["Café"]))
        var archived = active; archived.id = UUID(); archived.workspace?.archived = true
        var trash = active; trash.id = UUID(); trash.workspace?.trashedAt = Date()
        let records = [active, archived, trash]
        XCTAssertEqual(MessageLibrary.items(in: records).count, 4)
        let filtered = MessageLibrary.items(in: records, filter: .bookmarks, role: .assistant, scope: .archived, tag: "Café")
        XCTAssertEqual(filtered.count, 1); XCTAssertTrue(filtered[0].conversationArchived)
        XCTAssertEqual(filtered[0].conversationTags, ["Café"])
        XCTAssertEqual(MessageLibrary.items(in: records, query: "cafe", scope: .active).count, 2)
        XCTAssertTrue(MessageLibrary.items(in: records, tag: "其他").isEmpty)
        XCTAssertEqual(ConversationWorkbench.filtered(records, scope: .trash, query: "", tag: nil, sort: .recent).map(\.id), [trash.id])
    }

    @MainActor private func fixture(image: Bool = false, empty: Bool = false) throws -> SafetyFixture {
        let suite = "HermesSafetyTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("https://safety.hermes.test/v1", forKey: "serverURL"); defaults.set("default-model", forKey: "model")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var imageID: UUID?
        if image {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }.jpegData(compressionQuality: 0.8)!
            imageID = try ImageAttachmentStore.save(data, directory: directory.appendingPathComponent("Attachments"))
        }
        let first = Conversation(title: "保留的对话", messages: [ChatMessage(role: .user, content: "问题", imageID: imageID),
            ChatMessage(role: .assistant, content: "答案", bookmark: .init(createdAt: Date(), note: "私密备注"))],
            updatedAt: Date(), pinned: true, workspace: .init(tags: ["工作"], configuration: .init(systemPrompt: "简洁回答", contextTurns: 6)))
        let second = Conversation(title: "另一个引用", messages: [ChatMessage(role: .user, content: "同一张图", imageID: imageID)], updatedAt: Date(timeIntervalSince1970: 1))
        try JSONEncoder().encode(empty ? [] : [first, second]).write(to: directory.appendingPathComponent("conversations.json"))
        let keys = MemoryCredentials(); keys.values["api-server-key"] = "safety-fixture-key"
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return SafetyFixture(defaults: defaults, directory: directory, keys: keys)
    }
}

private struct SafetyFixture {
    let defaults: UserDefaults; let directory: URL; let keys: MemoryCredentials
    @MainActor func model() -> AppModel {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SafetyProtocol.self]
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: config)
    }
}

private final class SafetyProtocol: URLProtocol {
    static var handler: ((SafetyProtocol) -> Void)?
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.requests += 1; if let handler = Self.handler { handler(self) } else { respond() } }
    override func stopLoading() {}
    var body: Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); guard count > 0 else { break }; result.append(contentsOf: buffer.prefix(count)) }
        return result
    }
    func respond() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"完成\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
