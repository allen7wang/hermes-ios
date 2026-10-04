import XCTest
import UIKit
@testable import Hermes

final class MessageLibraryTests: XCTestCase {
    override func tearDown() { LibraryURLProtocol.handler = nil; super.tearDown() }

    func testOldMessageDecodesWithoutBookmarkAndNewMetadataRoundTrips() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"role\":\"assistant\",\"content\":\"旧回复\",\"createdAt\":0}".utf8)
        var message = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertNil(message.bookmark)
        message.bookmark = MessageBookmark(createdAt: Date(timeIntervalSince1970: 42), note: "留作参考")
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)), message)
    }

    func testLibraryFiltersBodyTitleNotesRoleAndBookmarkDates() {
        let first = ChatMessage(role: .assistant, content: "Release Café", createdAt: Date(timeIntervalSince1970: 30),
                                bookmark: MessageBookmark(createdAt: Date(timeIntervalSince1970: 10), note: "工程参考"))
        let second = ChatMessage(role: .user, content: "问题", createdAt: Date(timeIntervalSince1970: 20),
                                 bookmark: MessageBookmark(createdAt: Date(timeIntervalSince1970: 40), note: "待办"))
        let unsaved = ChatMessage(role: .assistant, content: "无收藏", createdAt: Date(timeIntervalSince1970: 50))
        let conversation = Conversation(title: "发布计划", messages: [first, second, unsaved], updatedAt: Date())
        XCTAssertEqual(MessageLibrary.items(in: [conversation]).map { $0.message.id }, [unsaved.id, first.id, second.id])
        XCTAssertEqual(MessageLibrary.items(in: [conversation], filter: .bookmarks).map { $0.message.id }, [second.id, first.id])
        XCTAssertEqual(MessageLibrary.items(in: [conversation], query: " cafe ").map { $0.message.id }, [first.id])
        XCTAssertEqual(MessageLibrary.items(in: [conversation], query: "工程").map { $0.message.id }, [first.id])
        XCTAssertEqual(MessageLibrary.items(in: [conversation], query: "发布", filter: .bookmarks, role: .user).map { $0.message.id }, [second.id])
        XCTAssertEqual(MessageLibrary.items(in: [conversation], filter: .bookmarks, role: .assistant).count, 1)
        XCTAssertTrue(MessageLibrary.items(in: [conversation], query: "不存在").isEmpty)
    }

    func testRepeatedMessageIDsAcrossConversationsHaveIndependentLibraryTargets() {
        let message = ChatMessage(role: .user, content: "相同标识的导入消息")
        let conversations = [Conversation(title: "A", messages: [message], updatedAt: Date()),
                             Conversation(title: "B", messages: [message], updatedAt: Date())]
        let entries = MessageLibrary.items(in: conversations)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        XCTAssertNotEqual(entries[0].id.conversationID, entries[1].id.conversationID)
        XCTAssertEqual(entries.map(\.id), MessageLibrary.items(in: conversations.reversed()).map(\.id))
    }

    func testQuotePreservesUnicodeBoundsAndMarksOmittedImageWithoutPrivateNote() {
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 4_001)
        let message = ChatMessage(role: .assistant, content: text, imageID: UUID(),
                                  bookmark: MessageBookmark(createdAt: Date(), note: "私人备注"))
        let item = MessageLibraryItem(id: LocalMessageTarget(conversationID: UUID(), messageID: message.id), conversationTitle: "测试", message: message)
        let quote = MessageLibrary.quote(item)
        XCTAssertTrue(quote.contains(String(text.prefix(4_000))))
        XCTAssertFalse(quote.contains(text))
        XCTAssertTrue(quote.contains("引用已截取前 4,000 字符"))
        XCTAssertTrue(quote.contains("图片未包含在引用中"))
        XCTAssertFalse(quote.contains("私人备注"))
        XCTAssertTrue(MessageLibrary.shareText(item).contains("私人备注"))
    }

    @MainActor func testBookmarkAndTrimmedNotePersistWithoutReorderingHistoryOrChangingDraft() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let original = model.conversations
        let selected = model.selectedID
        model.draft = "当前草稿"
        try model.toggleBookmark(fixture.target)
        let savedAt = try XCTUnwrap(model.libraryItem(fixture.target)?.message.bookmark?.createdAt)
        try model.updateBookmarkNote(fixture.target, note: "  发布参考 \n")
        XCTAssertEqual(model.libraryItem(fixture.target)?.message.bookmark?.note, "发布参考")
        XCTAssertEqual(model.libraryItem(fixture.target)?.message.bookmark?.createdAt, savedAt)
        XCTAssertEqual(model.conversations.map(\.id), original.map(\.id))
        XCTAssertEqual(model.conversations.map(\.updatedAt), original.map(\.updatedAt))
        XCTAssertEqual(model.selectedID, selected)
        XCTAssertEqual(model.draft, "当前草稿")
        let reopened = fixture.model()
        XCTAssertEqual(reopened.libraryItem(fixture.target)?.message.bookmark?.note, "发布参考")
        XCTAssertEqual(reopened.draft, "当前草稿")
    }

    @MainActor func testRemovingBookmarkClearsOnlyItsNoteAndBackupReturnsToVersionOne() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let content = model.libraryItem(fixture.target)?.message.content
        try model.toggleBookmark(fixture.target)
        try model.updateBookmarkNote(fixture.target, note: "备注")
        XCTAssertEqual(try model.makeBackup().version, 2)
        try model.toggleBookmark(fixture.target)
        XCTAssertNil(model.libraryItem(fixture.target)?.message.bookmark)
        XCTAssertEqual(model.libraryItem(fixture.target)?.message.content, content)
        XCTAssertEqual(try model.makeBackup().version, 1)
        XCTAssertThrowsError(try model.updateBookmarkNote(fixture.target, note: "不能悄悄重新收藏"))
    }

    @MainActor func testForeignProfileTargetsCannotBeReadBookmarkedQuotedOrOpened() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let home = model.activeProfileID
        _ = try model.saveProfile(id: nil, name: "工作", connection: ConnectionSettings(serverURL: "https://other.test", model: "agent", apiKey: "fixture"))
        model.draft = "保留工作草稿"
        XCTAssertNil(model.libraryItem(fixture.target))
        XCTAssertThrowsError(try model.toggleBookmark(fixture.target))
        XCTAssertThrowsError(try model.updateBookmarkNote(fixture.target, note: "跨连接"))
        XCTAssertThrowsError(try model.quoteMessage(fixture.target))
        XCTAssertThrowsError(try model.openMessage(fixture.target))
        XCTAssertEqual(model.draft, "保留工作草稿")
        XCTAssertTrue(MessageLibrary.items(in: model.conversations).isEmpty)
        model.selectProfile(home)
        XCTAssertNil(model.libraryItem(fixture.target)?.message.bookmark)
    }

    @MainActor func testBookmarkSaveFailureDoesNotPublishStarOrEditedNote() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let url = fixture.directory.appendingPathComponent("conversations.json")
        let before = try Data(contentsOf: url)
        try replaceWithDirectory(url)
        XCTAssertThrowsError(try model.toggleBookmark(fixture.target))
        XCTAssertNil(model.libraryItem(fixture.target)?.message.bookmark)
        try FileManager.default.removeItem(at: url); try before.write(to: url)
        try model.toggleBookmark(fixture.target)
        try model.updateBookmarkNote(fixture.target, note: "原备注")
        try replaceWithDirectory(url)
        XCTAssertThrowsError(try model.updateBookmarkNote(fixture.target, note: "不能显示保存成功"))
        XCTAssertEqual(model.libraryItem(fixture.target)?.message.bookmark?.note, "原备注")
    }

    @MainActor func testQuoteAppendsToCurrentDraftWithoutSwitchingSendingOrChangingSourceDraft() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let destination = try XCTUnwrap(model.selectedID)
        model.select(fixture.target.conversationID); model.draft = "源对话草稿"
        model.select(destination); model.draft = "目标对话草稿"
        try model.quoteMessage(fixture.target)
        XCTAssertEqual(model.selectedID, destination)
        XCTAssertTrue(model.draft.hasPrefix("目标对话草稿\n\n引用自「发布准备」"))
        XCTAssertTrue(model.draft.contains("> Release Café"))
        XCTAssertFalse(model.isSending)
        let reopened = fixture.model()
        XCTAssertEqual(reopened.draft, model.draft)
        reopened.select(fixture.target.conversationID)
        XCTAssertEqual(reopened.draft, "源对话草稿")
    }

    @MainActor func testDraftSaveFailureAndOversizedQuoteLeaveCurrentDraftUntouched() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        model.draft = "必须保留"
        try replaceWithDirectory(fixture.directory.appendingPathComponent("drafts.json"))
        XCTAssertThrowsError(try model.quoteMessage(fixture.target))
        XCTAssertEqual(model.draft, "必须保留")
        XCTAssertEqual(model.draftStore.text(for: model.draftKey), "必须保留")
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("drafts.json"))
        model.draft = String(repeating: "中", count: 100_000)
        XCTAssertThrowsError(try model.quoteMessage(fixture.target))
        XCTAssertEqual(model.draft.count, 100_000)
    }

    @MainActor func testOpeningSourceRestoresItsDraftAndRejectsDeletedMessage() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let destination = try XCTUnwrap(model.selectedID)
        model.select(fixture.target.conversationID); model.draft = "原文草稿"
        model.select(destination); model.draft = "当前草稿"
        try model.openMessage(fixture.target)
        XCTAssertEqual(model.selectedID, fixture.target.conversationID)
        XCTAssertEqual(model.draft, "原文草稿")
        model.delete(fixture.target.conversationID)
        XCTAssertThrowsError(try model.openMessage(fixture.target))
        XCTAssertThrowsError(try model.quoteMessage(fixture.target))
        XCTAssertThrowsError(try model.toggleBookmark(fixture.target))
        XCTAssertEqual(model.selectedID, destination)
        XCTAssertEqual(model.draft, "当前草稿")
    }

    @MainActor func testBranchesDoNotDuplicateBookmarkButPreserveOriginalAndImages() throws {
        let fixture = try makeFixture(withImage: true)
        let model = fixture.model()
        try model.toggleBookmark(fixture.target)
        try model.updateBookmarkNote(fixture.target, note: "仅属于原消息")
        try model.openMessage(fixture.target)
        XCTAssertTrue(model.branchConversation(at: fixture.target.messageID))
        XCTAssertNil(model.selectedConversation?.messages.last?.bookmark)
        XCTAssertEqual(model.selectedConversation?.messages.last?.imageID, model.libraryItem(fixture.target)?.message.imageID)
        XCTAssertEqual(MessageLibrary.items(in: model.conversations, filter: .bookmarks).count, 1)
        XCTAssertEqual(model.libraryItem(fixture.target)?.message.bookmark?.note, "仅属于原消息")
    }

    @MainActor func testVersionTwoBackupImportsNotesImagesAndPreservesLocalEditsOnRepeat() throws {
        let source = try makeFixture(withImage: true)
        let model = source.model()
        try model.toggleBookmark(source.target)
        try model.updateBookmarkNote(source.target, note: "收藏结论")
        let archive = try BackupArchive.decode(model.makeBackup().encoded())
        XCTAssertEqual(archive.version, 2)
        XCTAssertEqual(archive.bookmarkCount, 1)
        XCTAssertFalse(String(decoding: try archive.encoded(), as: UTF8.self).contains("library-fixture-key"))
        let destination = try makeFixture(empty: true)
        let restored = destination.model()
        _ = try restored.importBackup(archive)
        let profile = try XCTUnwrap(restored.profiles.first { $0.id != restored.activeProfileID })
        restored.selectProfile(profile.id)
        let item = try XCTUnwrap(MessageLibrary.items(in: restored.conversations, filter: .bookmarks).first)
        XCTAssertNotEqual(item.id.conversationID, source.target.conversationID)
        XCTAssertEqual(item.message.bookmark?.note, "收藏结论")
        XCTAssertNotNil(ImageAttachmentStore.image(try XCTUnwrap(item.message.imageID), directory: restored.attachmentDirectory))
        try restored.updateBookmarkNote(item.id, note: "本机新备注")
        _ = try restored.importBackup(archive)
        XCTAssertEqual(MessageLibrary.items(in: restored.conversations, filter: .bookmarks).count, 1)
        XCTAssertEqual(restored.libraryItem(item.id)?.message.bookmark?.note, "本机新备注")
    }

    @MainActor func testArchiveRejectsDowngradedBookmarkMetadataAndInvalidNoteBeforeImport() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        try model.toggleBookmark(fixture.target)
        let archive = try model.makeBackup()
        var downgraded = archive; downgraded.version = 1
        XCTAssertThrowsError(try downgraded.validate())
        var tooLong = archive
        for i in tooLong.conversations.indices {
            for j in tooLong.conversations[i].messages.indices where tooLong.conversations[i].messages[j].bookmark != nil {
                tooLong.conversations[i].messages[j].bookmark?.note = String(repeating: "字", count: 2_001)
            }
        }
        let destination = try makeFixture(empty: true).model()
        XCTAssertThrowsError(try destination.importBackup(tooLong))
        XCTAssertTrue(destination.conversations.isEmpty)
        XCTAssertEqual(destination.profiles.count, 1)
        XCTAssertThrowsError(try model.updateBookmarkNote(fixture.target, note: String(repeating: "👨‍👩‍👧‍👦", count: 2_001)))
        try model.updateBookmarkNote(fixture.target, note: String(repeating: "👨‍👩‍👧‍👦", count: 2_000))
        XCTAssertEqual(model.libraryItem(fixture.target)?.message.bookmark?.note.count, 2_000)
    }

    @MainActor func testBookmarksAndQuotesWorkDuringGenerationButOpeningSourceIsBlocked() async throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let original = try XCTUnwrap(model.selectedID)
        let started = expectation(description: "request started")
        var pending: LibraryURLProtocol?
        LibraryURLProtocol.handler = { pending = $0; started.fulfill() }
        XCTAssertTrue(model.send("继续"))
        await fulfillment(of: [started], timeout: 3)
        try model.toggleBookmark(fixture.target)
        try model.updateBookmarkNote(fixture.target, note: "后台生成时也可编辑")
        try model.quoteMessage(fixture.target)
        XCTAssertThrowsError(try model.openMessage(fixture.target))
        XCTAssertEqual(model.selectedID, original)
        pending?.respond()
        await finish(model)
        XCTAssertEqual(model.libraryItem(fixture.target)?.message.bookmark?.note, "后台生成时也可编辑")
        XCTAssertTrue(model.draft.contains("Release Café"))
    }

    @MainActor func testChatRequestNeverSerializesBookmarkNotesOrDates() async throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        try model.openMessage(fixture.target)
        try model.toggleBookmark(fixture.target)
        try model.updateBookmarkNote(fixture.target, note: "私人收藏备注")
        let started = expectation(description: "payload inspected")
        LibraryURLProtocol.handler = { request in
            let body = String(decoding: request.body, as: UTF8.self)
            XCTAssertFalse(body.contains("bookmark"))
            XCTAssertFalse(body.contains("私人收藏备注"))
            request.respond(); started.fulfill()
        }
        XCTAssertTrue(model.send("新问题"))
        await fulfillment(of: [started], timeout: 3)
        await finish(model)
    }

    @MainActor func testCorruptStorageIsPreservedAndNewLibraryMutationsAreBlocked() throws {
        let fixture = try makeFixture()
        let original = Data("damaged history".utf8)
        let url = fixture.directory.appendingPathComponent("conversations.json")
        try original.write(to: url)
        let model = fixture.model()
        XCTAssertTrue(model.needsRecovery)
        XCTAssertThrowsError(try model.toggleBookmark(fixture.target))
        XCTAssertThrowsError(try model.quoteMessage(fixture.target))
        XCTAssertThrowsError(try model.openMessage(fixture.target))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testImageOnlyMessagesRemainBrowsableSearchableByTitleAndQuotedAsText() {
        let message = ChatMessage(role: .user, content: "", imageID: UUID(), bookmark: MessageBookmark(createdAt: Date(), note: "图片参考"))
        let conversation = Conversation(title: "照片计划", messages: [message], updatedAt: Date())
        let item = MessageLibrary.items(in: [conversation], query: "照片", filter: .bookmarks).first!
        XCTAssertEqual(item.preview, "[图片]")
        XCTAssertTrue(MessageLibrary.quote(item).contains("> [图片]"))
        XCTAssertTrue(MessageLibrary.items(in: [conversation], query: "图片参考").count == 1)
    }

    func testCancelledSearchDoesNotReturnStaleResults() async {
        let conversation = Conversation(title: "旧搜索", messages: [ChatMessage(role: .user, content: "结果")], updatedAt: Date())
        let search = Task.detached {
            try? await Task.sleep(for: .seconds(5))
            return MessageLibrary.items(in: [conversation])
        }
        search.cancel()
        let result = await search.value
        XCTAssertTrue(result.isEmpty)
    }

    @MainActor func testInterruptedVersionTwoImportRecoversBookmarksOnRelaunch() throws {
        let source = try makeFixture()
        let model = source.model()
        try model.toggleBookmark(source.target)
        try model.updateBookmarkNote(source.target, note: "恢复这条备注")
        let archive = try model.makeBackup()
        let fixture = try makeFixture(empty: true)
        let destination = fixture.model()
        let draftsURL = fixture.directory.appendingPathComponent("drafts.json")
        try replaceWithDirectory(draftsURL)
        XCTAssertThrowsError(try destination.importBackup(archive))
        try FileManager.default.removeItem(at: draftsURL)
        let reopened = fixture.model()
        let profile = try XCTUnwrap(reopened.profiles.first { $0.id != reopened.activeProfileID })
        reopened.selectProfile(profile.id)
        XCTAssertEqual(MessageLibrary.items(in: reopened.conversations, filter: .bookmarks).first?.message.bookmark?.note, "恢复这条备注")
        XCTAssertFalse(reopened.needsRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("pending-restore.json").path))
    }

    private func replaceWithDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    @MainActor private func finish(_ model: AppModel) async {
        for _ in 0..<150 where model.isSending { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSending)
    }

    @MainActor private func makeFixture(withImage: Bool = false, empty: Bool = false) throws -> LibraryFixture {
        let suite = "HermesLibraryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set("https://hermes.test/v1", forKey: "serverURL")
        let keys = MemoryCredentials(); keys.values["api-server-key"] = "library-fixture-key"
        var imageID: UUID?
        if withImage {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }.jpegData(compressionQuality: 0.8)!
            imageID = try ImageAttachmentStore.save(data, directory: directory.appendingPathComponent("Attachments"))
        }
        let answer = ChatMessage(role: .assistant, content: "Release Café", imageID: imageID)
        let source = Conversation(title: "发布准备", messages: [ChatMessage(role: .user, content: "发布问题"), answer], updatedAt: Date(timeIntervalSince1970: 1))
        let current = Conversation(title: "当前工作", messages: [ChatMessage(role: .user, content: "下一步"), ChatMessage(role: .assistant, content: "继续工作")], updatedAt: Date(timeIntervalSince1970: 2))
        try JSONEncoder().encode(empty ? [] : [source, current]).write(to: directory.appendingPathComponent("conversations.json"))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return LibraryFixture(defaults: defaults, directory: directory, keys: keys,
                              target: LocalMessageTarget(conversationID: source.id, messageID: answer.id))
    }
}

private struct LibraryFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    let target: LocalMessageTarget
    @MainActor func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryURLProtocol.self]
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: configuration)
    }
}

private final class LibraryURLProtocol: URLProtocol {
    static var handler: ((LibraryURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    var body: Data {
        if let data = request.httpBody { return data }
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
    func respond() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"新回复\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
