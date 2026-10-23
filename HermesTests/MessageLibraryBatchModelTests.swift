import XCTest
import UIKit
@testable import Hermes

final class MessageLibraryBatchModelTests: XCTestCase {
    override func tearDown() {
        BatchLibraryURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor func testSnapshotUsesCanonicalOrderCompositeTargetsAndSourceMetadata() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let targets = [fixture.savedTarget, fixture.archivedTarget, fixture.unsavedTarget]
        let before = try fixture.historyData()
        let snapshot = try model.makeMessageLibraryBatch(targets, profileID: model.activeProfileID)
        XCTAssertEqual(snapshot.profileID, model.activeProfileID)
        XCTAssertEqual(snapshot.profileName, "测试连接")
        XCTAssertEqual(snapshot.items.map(\.id), [fixture.archivedTarget, fixture.unsavedTarget, fixture.savedTarget])
        XCTAssertEqual(snapshot.items[0].conversationTitle, "历史方案")
        XCTAssertTrue(snapshot.items[0].conversationArchived)
        XCTAssertEqual(snapshot.items[0].conversationTags, ["归档"])
        XCTAssertEqual(snapshot.items[0].message.id, snapshot.items[1].message.id)
        XCTAssertNotEqual(snapshot.items[0].id, snapshot.items[1].id)
        XCTAssertEqual(snapshot.items[2].message.bookmark?.note, "原始备注")
        XCTAssertEqual(try fixture.historyData(), before)
    }

    @MainActor func testSnapshotRejectsEmptyDuplicateMissingTrashAndWrongProfileSelections() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let profileID = model.activeProfileID
        let invalidSelections: [[LocalMessageTarget]] = [
            [], [fixture.savedTarget, fixture.savedTarget],
            [fixture.savedTarget, LocalMessageTarget(conversationID: fixture.savedTarget.conversationID, messageID: UUID())],
            [fixture.savedTarget, LocalMessageTarget(conversationID: UUID(), messageID: fixture.savedTarget.messageID)],
            [fixture.savedTarget, fixture.trashTarget], [fixture.savedTarget, fixture.foreignTarget]
        ]
        let before = try fixture.historyData()
        for selection in invalidSelections {
            XCTAssertThrowsError(try model.makeMessageLibraryBatch(selection, profileID: profileID))
        }
        XCTAssertThrowsError(try model.makeMessageLibraryBatch([fixture.savedTarget], profileID: fixture.foreignProfileID))
        XCTAssertEqual(try fixture.historyData(), before)
        XCTAssertNil(model.libraryItem(fixture.unsavedTarget)?.message.bookmark)
    }

    @MainActor func testSelectionCountAndFullSelectedTextAreBoundedBeforeAnyWrite() throws {
        let fixture = try makeFixture()
        var records = try fixture.history()
        let index = try XCTUnwrap(records.firstIndex { $0.id == fixture.currentID })
        records[index].messages = (0..<101).map { ChatMessage(role: .assistant, content: "短消息 \($0)") }
        try fixture.writeHistory(records)
        let model = fixture.model()
        let targets = records[index].messages.map { LocalMessageTarget(conversationID: fixture.currentID, messageID: $0.id) }
        XCTAssertEqual(try model.makeMessageLibraryBatch(Array(targets.prefix(100)), profileID: model.activeProfileID).items.count, 100)
        XCTAssertThrowsError(try model.makeMessageLibraryBatch(targets, profileID: model.activeProfileID))
        records[index].messages = [ChatMessage(role: .assistant, content: String(repeating: "字", count: 500_001))]
        try fixture.writeHistory(records)
        let largeModel = fixture.model()
        let largeTarget = LocalMessageTarget(conversationID: fixture.currentID, messageID: records[index].messages[0].id)
        let before = try fixture.historyData()
        XCTAssertThrowsError(try largeModel.makeMessageLibraryBatch([largeTarget], profileID: largeModel.activeProfileID))
        XCTAssertEqual(try fixture.historyData(), before)
    }

    @MainActor func testMixedAddPreservesExistingBookmarkAndAllUnrelatedState() throws {
        let fixture = try makeFixture(withImage: true)
        let model = fixture.model()
        model.select(fixture.currentID)
        model.draft = "本机未发送草稿"
        let before = try fixture.history()
        let selected = model.selectedID
        let drafts = try model.draftStore.snapshot()
        let imageURL = try XCTUnwrap(fixture.imageURL)
        let imageData = try Data(contentsOf: imageURL)
        let targets = [fixture.unsavedTarget, fixture.savedTarget, fixture.archivedTarget]
        let snapshot = try model.makeMessageLibraryBatch(targets, profileID: model.activeProfileID)
        let report = try model.changeMessageLibraryBookmarks(snapshot, operation: .add)
        XCTAssertEqual(report.requested, 3)
        XCTAssertEqual(report.changed, 2)
        XCTAssertEqual(report.unchanged, 1)
        XCTAssertEqual(report.notesRemoved, 0)
        let firstDate = try XCTUnwrap(model.libraryItem(fixture.unsavedTarget)?.message.bookmark?.createdAt)
        XCTAssertEqual(model.libraryItem(fixture.archivedTarget)?.message.bookmark?.createdAt, firstDate)
        XCTAssertEqual(model.libraryItem(fixture.savedTarget)?.message.bookmark,
                       snapshot.items.first { $0.id == fixture.savedTarget }?.message.bookmark)
        XCTAssertEqual(model.libraryItem(fixture.unsavedTarget)?.message.bookmark?.note, "")
        var expected = before
        for conversationIndex in expected.indices {
            for messageIndex in expected[conversationIndex].messages.indices {
                let target = LocalMessageTarget(conversationID: expected[conversationIndex].id,
                                                messageID: expected[conversationIndex].messages[messageIndex].id)
                if target == fixture.unsavedTarget || target == fixture.archivedTarget {
                    expected[conversationIndex].messages[messageIndex].bookmark = MessageBookmark(createdAt: firstDate, note: "")
                }
            }
        }
        XCTAssertEqual(try fixture.history(), expected)
        XCTAssertEqual(model.selectedID, selected)
        XCTAssertEqual(model.draft, "本机未发送草稿")
        XCTAssertEqual(try model.draftStore.snapshot(), drafts)
        XCTAssertEqual(try Data(contentsOf: imageURL), imageData)
        let reopened = fixture.model()
        XCTAssertEqual(reopened.conversations, model.conversations)
        XCTAssertEqual(reopened.trashedConversations, model.trashedConversations)
        XCTAssertEqual(reopened.draft, "本机未发送草稿")
    }

    @MainActor func testRemoveClearsOnlySelectedBookmarksAndCountsLostNotes() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        try model.toggleBookmark(fixture.archivedTarget)
        try model.updateBookmarkNote(fixture.archivedTarget, note: "第二份备注")
        let before = try fixture.history()
        let targets = [fixture.savedTarget, fixture.archivedTarget, fixture.unsavedTarget]
        let snapshot = try model.makeMessageLibraryBatch(targets, profileID: model.activeProfileID)
        let report = try model.changeMessageLibraryBookmarks(snapshot, operation: .remove)
        XCTAssertEqual(report.requested, 3)
        XCTAssertEqual(report.changed, 2)
        XCTAssertEqual(report.unchanged, 1)
        XCTAssertEqual(report.notesRemoved, 2)
        var expected = before
        for conversationIndex in expected.indices {
            for messageIndex in expected[conversationIndex].messages.indices {
                let target = LocalMessageTarget(conversationID: expected[conversationIndex].id,
                                                messageID: expected[conversationIndex].messages[messageIndex].id)
                if targets.contains(target) { expected[conversationIndex].messages[messageIndex].bookmark = nil }
            }
        }
        XCTAssertEqual(try fixture.history(), expected)
        XCTAssertEqual(fixture.model().conversations, model.conversations)
    }

    @MainActor func testNoOpAddAndRemoveDoNotAttemptAnUnwritableHistoryFile() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let add = try model.makeMessageLibraryBatch([fixture.savedTarget], profileID: model.activeProfileID)
        let remove = try model.makeMessageLibraryBatch([fixture.unsavedTarget], profileID: model.activeProfileID)
        let before = model.conversations
        try replaceWithDirectory(fixture.historyURL)
        for (snapshot, operation) in [(add, MessageLibraryBatchOperation.add), (remove, .remove)] {
            let report = try model.changeMessageLibraryBookmarks(snapshot, operation: operation)
            XCTAssertEqual(report.requested, 1)
            XCTAssertEqual(report.changed, 0)
            XCTAssertEqual(report.unchanged, 1)
            XCTAssertEqual(report.notesRemoved, 0)
        }
        XCTAssertEqual(model.conversations, before)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.historyURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(model.needsRecovery)
    }

    @MainActor func testFailedAtomicWritePublishesNeitherPartialStarsNorRemovedNotes() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let before = model.conversations
        let data = try fixture.historyData()
        let add = try model.makeMessageLibraryBatch([fixture.unsavedTarget, fixture.archivedTarget], profileID: model.activeProfileID)
        let remove = try model.makeMessageLibraryBatch([fixture.savedTarget], profileID: model.activeProfileID)
        try replaceWithDirectory(fixture.historyURL)
        XCTAssertThrowsError(try model.changeMessageLibraryBookmarks(add, operation: .add))
        XCTAssertThrowsError(try model.changeMessageLibraryBookmarks(remove, operation: .remove))
        XCTAssertEqual(model.conversations, before)
        XCTAssertEqual(model.libraryItem(fixture.savedTarget)?.message.bookmark?.note, "原始备注")
        try FileManager.default.removeItem(at: fixture.historyURL)
        try data.write(to: fixture.historyURL)
        XCTAssertEqual(fixture.model().conversations, before)
    }

    @MainActor func testChangedNoteInvalidatesWholeBatchIncludingOtherwiseUnchangedTargets() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let snapshot = try model.makeMessageLibraryBatch([fixture.unsavedTarget, fixture.savedTarget], profileID: model.activeProfileID)
        try model.updateBookmarkNote(fixture.savedTarget, note: "刚刚更新的备注")
        let before = try fixture.historyData()
        XCTAssertThrowsError(try model.changeMessageLibraryBookmarks(snapshot, operation: .add))
        XCTAssertNil(model.libraryItem(fixture.unsavedTarget)?.message.bookmark)
        XCTAssertEqual(model.libraryItem(fixture.savedTarget)?.message.bookmark?.note, "刚刚更新的备注")
        XCTAssertEqual(try fixture.historyData(), before)
    }

    @MainActor func testChangedTitleTagsArchiveProjectNameAndSameNameProjectAssignmentRejectOldSnapshot() throws {
        for change in ["title", "tags", "archive", "projectName", "projectAssignment"] {
            let fixture = try makeFixture()
            let model = fixture.model()
            let projectID = try model.saveProject(id: nil, name: "研究", summary: "", instructions: "", profileID: model.activeProfileID)
            try model.assignConversations([fixture.savedTarget.conversationID], toProject: projectID, profileID: model.activeProfileID)
            let snapshot = try model.makeMessageLibraryBatch([fixture.unsavedTarget, fixture.savedTarget], profileID: model.activeProfileID)
            switch change {
            case "title": model.rename(fixture.savedTarget.conversationID, to: "新的来源标题")
            case "tags":
                model.select(fixture.savedTarget.conversationID)
                try model.saveConversationSettings(title: "准备发布", tags: "不同标签", configuration: model.conversationConfiguration,
                                                   expectedDraftKey: model.draftKey, profileID: model.activeProfileID)
            case "archive": try model.setArchived([fixture.savedTarget.conversationID], archived: true)
            case "projectName":
                _ = try model.saveProject(id: projectID, name: "研究新名称", summary: "", instructions: "", profileID: model.activeProfileID)
            default:
                let secondID = try model.saveProject(id: nil, name: "研究", summary: "", instructions: "", profileID: model.activeProfileID)
                try model.assignConversations([fixture.savedTarget.conversationID], toProject: secondID, profileID: model.activeProfileID)
            }
            let before = try fixture.historyData()
            XCTAssertThrowsError(try model.changeMessageLibraryBookmarks(snapshot, operation: .add), change)
            XCTAssertEqual(try fixture.historyData(), before, change)
            XCTAssertNil(model.libraryItem(fixture.unsavedTarget)?.message.bookmark, change)
        }
    }

    @MainActor func testTrashingOrDeletingOneSourceRejectsWholeBatch() throws {
        for permanentlyDelete in [false, true] {
            let fixture = try makeFixture()
            let model = fixture.model()
            let snapshot = try model.makeMessageLibraryBatch([fixture.unsavedTarget, fixture.archivedTarget], profileID: model.activeProfileID)
            try model.deleteConversations([fixture.archivedTarget.conversationID])
            if permanentlyDelete { try model.permanentlyDeleteConversations([fixture.archivedTarget.conversationID]) }
            let before = try fixture.historyData()
            XCTAssertThrowsError(try model.changeMessageLibraryBookmarks(snapshot, operation: .add))
            XCTAssertEqual(try fixture.historyData(), before)
            XCTAssertNil(model.libraryItem(fixture.unsavedTarget)?.message.bookmark)
        }
    }

    @MainActor func testSwitchingProfileAndRenamingProfileInvalidateSnapshot() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let profileID = model.activeProfileID
        let snapshot = try model.makeMessageLibraryBatch([fixture.unsavedTarget], profileID: profileID)
        model.selectProfile(fixture.foreignProfileID)
        let before = try fixture.historyData()
        XCTAssertThrowsError(try model.changeMessageLibraryBookmarks(snapshot, operation: .add))
        XCTAssertEqual(try fixture.historyData(), before)
        model.selectProfile(profileID)
        _ = try model.saveProfile(id: profileID, name: "重命名连接", connection: model.settings)
        XCTAssertThrowsError(try model.changeMessageLibraryBookmarks(snapshot, operation: .add))
        XCTAssertNil(model.libraryItem(fixture.unsavedTarget)?.message.bookmark)
    }

    @MainActor func testUnrelatedPinConfigurationDraftAndProjectSummaryEditsDoNotInvalidateSnapshot() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let projectID = try model.saveProject(id: nil, name: "研究", summary: "原说明", instructions: "原指令", profileID: model.activeProfileID)
        try model.assignConversations([fixture.savedTarget.conversationID], toProject: projectID, profileID: model.activeProfileID)
        let snapshot = try model.makeMessageLibraryBatch([fixture.unsavedTarget], profileID: model.activeProfileID)
        model.togglePin(fixture.unsavedTarget.conversationID)
        model.select(fixture.currentID)
        model.draft = "本机新草稿"
        var configuration = model.conversationConfiguration
        configuration.systemPrompt = "只改变另一段对话的设置"
        try model.saveConversationSettings(title: "当前工作", tags: "", configuration: configuration,
                                           expectedDraftKey: model.draftKey, profileID: model.activeProfileID)
        _ = try model.saveProject(id: projectID, name: "研究", summary: "新的说明", instructions: "新的指令", profileID: model.activeProfileID)
        let report = try model.changeMessageLibraryBookmarks(snapshot, operation: .add)
        XCTAssertEqual(report.changed, 1)
        XCTAssertEqual(model.draft, "本机新草稿")
        XCTAssertEqual(model.selectedID, fixture.currentID)
        XCTAssertTrue(try XCTUnwrap(model.conversations.first { $0.id == fixture.unsavedTarget.conversationID }).isPinned)
        XCTAssertEqual(model.conversationConfiguration.systemPrompt, "只改变另一段对话的设置")
    }

    @MainActor func testBatchWorksWhileGenerationAppendsMessagesAndBookmarksSurviveCompletion() async throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        model.select(fixture.currentID)
        let currentMessage = try XCTUnwrap(model.selectedConversation?.messages.last)
        let currentTarget = LocalMessageTarget(conversationID: fixture.currentID, messageID: currentMessage.id)
        let snapshot = try model.makeMessageLibraryBatch([fixture.unsavedTarget, currentTarget], profileID: model.activeProfileID)
        let started = expectation(description: "controlled request is waiting")
        var pending: BatchLibraryURLProtocol?
        BatchLibraryURLProtocol.handler = { pending = $0; started.fulfill() }
        XCTAssertTrue(model.send("继续生成"))
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(model.isSending)
        model.draft = "生成期间的新草稿"
        let report = try model.changeMessageLibraryBookmarks(snapshot, operation: .add)
        XCTAssertEqual(report.changed, 2)
        XCTAssertTrue(model.isSending)
        XCTAssertEqual(model.selectedID, fixture.currentID)
        pending?.respond()
        for _ in 0..<150 where model.isSending { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.draft, "生成期间的新草稿")
        XCTAssertEqual(model.selectedConversation?.messages.last?.content, "批处理期间生成的回复")
        let reopened = fixture.model()
        XCTAssertNotNil(reopened.libraryItem(fixture.unsavedTarget)?.message.bookmark)
        XCTAssertNotNil(reopened.libraryItem(currentTarget)?.message.bookmark)
        XCTAssertEqual(reopened.draft, "生成期间的新草稿")
    }

    @MainActor func testBackupNeedsOnlyExistingBookmarkVersionAndRoundTripsBatchChanges() throws {
        let fixture = try makeFixture(minimal: true)
        let model = fixture.model()
        XCTAssertEqual(try model.makeBackup().version, 1)
        let snapshot = try model.makeMessageLibraryBatch([fixture.unsavedTarget, fixture.savedTarget], profileID: model.activeProfileID)
        _ = try model.changeMessageLibraryBookmarks(snapshot, operation: .add)
        try model.updateBookmarkNote(fixture.savedTarget, note: "批量整理后的备注")
        let archive = try BackupArchive.decode(model.makeBackup().encoded())
        XCTAssertEqual(archive.version, 2)
        XCTAssertEqual(archive.bookmarkCount, 2)
        XCTAssertEqual(archive.conversations.flatMap(\.messages).compactMap(\.bookmark).filter { !$0.note.isEmpty }.map(\.note), ["批量整理后的备注"])
        let current = try model.makeMessageLibraryBatch([fixture.unsavedTarget, fixture.savedTarget], profileID: model.activeProfileID)
        _ = try model.changeMessageLibraryBookmarks(current, operation: .remove)
        XCTAssertEqual(try model.makeBackup().version, 1)
        XCTAssertEqual(try model.makeBackup().bookmarkCount, 0)
    }

    @MainActor func testRecoveryBlocksSnapshotAndMutationWithoutOverwritingCorruptStorage() throws {
        let fixture = try makeFixture()
        let originalModel = fixture.model()
        let snapshot = try originalModel.makeMessageLibraryBatch([fixture.unsavedTarget], profileID: originalModel.activeProfileID)
        let corrupt = Data("not a JSON history".utf8)
        try corrupt.write(to: fixture.historyURL)
        let model = fixture.model()
        XCTAssertTrue(model.needsRecovery)
        XCTAssertThrowsError(try model.makeMessageLibraryBatch([fixture.unsavedTarget], profileID: model.activeProfileID))
        XCTAssertThrowsError(try model.changeMessageLibraryBookmarks(snapshot, operation: .add))
        XCTAssertEqual(try fixture.historyData(), corrupt)
    }

    private func replaceWithDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    @MainActor private func makeFixture(withImage: Bool = false, minimal: Bool = false) throws -> BatchLibraryFixture {
        let suite = "HermesBatchLibraryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profileID = ConnectionProfile.legacyID
        let foreignProfileID = UUID()
        let profiles = [ConnectionProfile(id: profileID, name: "测试连接", serverURL: "https://hermes.test/v1", model: "agent"),
                        ConnectionProfile(id: foreignProfileID, name: "另一连接", serverURL: "https://other.test/v1", model: "agent")]
        let keys = MemoryCredentials()
        keys.values["api-server-key"] = "batch-library-fixture-key"
        var imageID: UUID?
        var imageURL: URL?
        if withImage {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }.jpegData(compressionQuality: 0.8)!
            let attachments = directory.appendingPathComponent("Attachments")
            imageID = try ImageAttachmentStore.save(data, directory: attachments)
            imageURL = try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil).first
        }
        let saved = ChatMessage(role: .assistant, content: "保存结论", createdAt: Date(timeIntervalSince1970: 100),
                                bookmark: minimal ? nil : MessageBookmark(createdAt: Date(timeIntervalSince1970: 200), note: "原始备注"))
        let unsaved = ChatMessage(role: .assistant, content: "待整理", createdAt: Date(timeIntervalSince1970: 101), imageID: imageID)
        var main = Conversation(title: "准备发布", messages: [saved, unsaved], updatedAt: Date(timeIntervalSince1970: 300), profileID: profileID)
        if !minimal { main.workspace = ConversationWorkspace(tags: ["发布"], configuration: ConversationConfiguration(systemPrompt: "保留设置")) }
        let archivedMessage = ChatMessage(id: unsaved.id, role: .user, content: "独立消息", createdAt: Date(timeIntervalSince1970: 102))
        let archived = Conversation(title: "历史方案", messages: [archivedMessage], updatedAt: Date(timeIntervalSince1970: 301), profileID: profileID,
                                    workspace: ConversationWorkspace(tags: ["归档"], archived: true))
        let current = Conversation(title: "当前工作", messages: [ChatMessage(role: .user, content: "下一步"), ChatMessage(role: .assistant, content: "继续")],
                                   updatedAt: Date(timeIntervalSince1970: 302), profileID: profileID)
        let trashMessage = ChatMessage(role: .assistant, content: "回收站收藏", bookmark: MessageBookmark(createdAt: Date(timeIntervalSince1970: 201), note: "不应移除"))
        let trash = Conversation(title: "已删除", messages: [trashMessage], updatedAt: Date(timeIntervalSince1970: 303), profileID: profileID,
                                 workspace: ConversationWorkspace(trashedAt: Date(timeIntervalSince1970: 400)))
        let foreignMessage = ChatMessage(id: unsaved.id, role: .assistant, content: "另一连接的独立收藏",
                                         bookmark: MessageBookmark(createdAt: Date(timeIntervalSince1970: 202), note: "保留跨连接备注"))
        let foreign = Conversation(title: "其他空间", messages: [foreignMessage], updatedAt: Date(timeIntervalSince1970: 304), profileID: foreignProfileID)
        let records = minimal ? [main, current] : [main, archived, current, trash, foreign]
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("conversations.json"))
        let library = ConnectionLibrary(profiles: profiles, activeID: profileID, selectedConversations: [profileID.uuidString: current.id.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return BatchLibraryFixture(defaults: defaults, directory: directory, keys: keys, currentID: current.id, foreignProfileID: foreignProfileID,
                                   savedTarget: LocalMessageTarget(conversationID: main.id, messageID: saved.id),
                                   unsavedTarget: LocalMessageTarget(conversationID: main.id, messageID: unsaved.id),
                                   archivedTarget: LocalMessageTarget(conversationID: archived.id, messageID: archivedMessage.id),
                                   trashTarget: LocalMessageTarget(conversationID: trash.id, messageID: trashMessage.id),
                                   foreignTarget: LocalMessageTarget(conversationID: foreign.id, messageID: foreignMessage.id), imageURL: imageURL)
    }
}

private struct BatchLibraryFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    let currentID: UUID
    let foreignProfileID: UUID
    let savedTarget: LocalMessageTarget
    let unsavedTarget: LocalMessageTarget
    let archivedTarget: LocalMessageTarget
    let trashTarget: LocalMessageTarget
    let foreignTarget: LocalMessageTarget
    let imageURL: URL?
    var historyURL: URL { directory.appendingPathComponent("conversations.json") }
    func historyData() throws -> Data { try Data(contentsOf: historyURL) }
    func history() throws -> [Conversation] { try JSONDecoder().decode([Conversation].self, from: historyData()) }
    func writeHistory(_ records: [Conversation]) throws { try JSONEncoder().encode(records).write(to: historyURL) }
    @MainActor func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BatchLibraryURLProtocol.self]
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: configuration)
    }
}

private final class BatchLibraryURLProtocol: URLProtocol {
    static var handler: ((BatchLibraryURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("Unexpected network request: \(request.url?.absoluteString ?? "unknown")")
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        handler(self)
    }
    override func stopLoading() {}
    func respond() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"批处理期间生成的回复\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
