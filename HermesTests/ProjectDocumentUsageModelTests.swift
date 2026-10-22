import XCTest
@testable import Hermes

final class ProjectDocumentUsageModelTests: XCTestCase {
    @MainActor func testUsageQueriesAndReviewAreReadOnlyAndLimitedToCurrentProjectAndProfile() throws {
        let f = try UsageModelFixture.make(owner: self); let model = f.model()
        model.draft = "尚未发送的独立草稿"
        let before = try model.makeBackup(); let selectedID = model.selectedID
        let connections = try Data(contentsOf: f.directory.appendingPathComponent("connections.json"))
        let conversations = try Data(contentsOf: f.directory.appendingPathComponent("conversations.json"))

        let records = model.projectDocumentConversations(projectID: f.projectID, profileID: f.profileID)
        XCTAssertEqual(Set(records.map(\.id)), Set([f.activeID, f.archivedID, f.trashID, f.unreferencedID]))
        _ = try model.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID)

        let after = try model.makeBackup()
        XCTAssertEqual(after.profiles, before.profiles); XCTAssertEqual(after.conversations, before.conversations)
        XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(after.images, before.images)
        XCTAssertEqual(model.selectedID, selectedID); XCTAssertEqual(model.draft, "尚未发送的独立草稿")
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("connections.json")), connections)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("conversations.json")), conversations)
    }

    @MainActor func testReviewIncludesArchiveAndTrashOnceAndKeepsActualReferenceSlotNumbers() throws {
        let f = try UsageModelFixture.make(owner: self); let model = f.model()
        let review = try model.reviewProjectDocumentDeletion([f.documents[0], f.documents[2]], projectID: f.projectID, profileID: f.profileID)
        XCTAssertEqual(review.profileID, f.profileID); XCTAssertEqual(review.projectID, f.projectID)
        XCTAssertEqual(review.projectName, "引用检查项目")
        XCTAssertEqual(review.documents, [f.documents[0], f.documents[2]])
        XCTAssertEqual(review.references.count, 3)
        let active = try XCTUnwrap(review.references.first { $0.conversationID == f.activeID })
        let archived = try XCTUnwrap(review.references.first { $0.conversationID == f.archivedID })
        let trash = try XCTUnwrap(review.references.first { $0.conversationID == f.trashID })
        XCTAssertEqual(active.title, "进行中的研究")
        XCTAssertEqual(active.status, .active); XCTAssertEqual(archived.status, .archived); XCTAssertEqual(trash.status, .trash)
        XCTAssertEqual(active.slots.map(\.documentID), [f.documents[2].id, f.documents[0].id])
        XCTAssertEqual(active.slots.map(\.number), [1, 2])
        XCTAssertEqual(archived.slots.map(\.number), [2])
        XCTAssertEqual(trash.slots.map(\.number), [1, 2])
        XCTAssertEqual(Set(review.references.map(\.conversationID)).count, review.references.count)
    }

    @MainActor func testNewReferenceAfterReviewRejectsDeletionWithoutChangingStoredState() throws {
        let f = try UsageModelFixture.make(owner: self); let model = f.model()
        let review = try model.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID)
        try model.selectProjectDocuments([f.documents[0].id], conversationID: f.unreferencedID, profileID: f.profileID)
        let before = try model.makeBackup()
        assertChangedReferences { try model.deleteReviewedProjectDocuments(review) }
        assertUnchanged(model, before: before)
    }

    @MainActor func testRemovedReferenceAfterReviewRejectsDeletionWithoutChangingStoredState() throws {
        let f = try UsageModelFixture.make(owner: self); let model = f.model()
        let review = try model.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID)
        try model.selectProjectDocuments([f.documents[1].id], conversationID: f.archivedID, profileID: f.profileID)
        let before = try model.makeBackup()
        assertChangedReferences { try model.deleteReviewedProjectDocuments(review) }
        assertUnchanged(model, before: before)
    }

    @MainActor func testAffectedConversationTitleArchiveAndTrashChangesRequireNewReview() throws {
        for mutation in 0..<3 {
            let f = try UsageModelFixture.make(owner: self); let model = f.model()
            let review = try model.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID)
            switch mutation {
            case 0: model.rename(f.activeID, to: "检查后修改的标题")
            case 1: try model.setArchived([f.activeID], archived: true)
            default: try model.deleteConversations([f.activeID])
            }
            let before = try model.makeBackup()
            assertChangedReferences { try model.deleteReviewedProjectDocuments(review) }
            assertUnchanged(model, before: before)
        }
    }

    @MainActor func testAffectedReferenceRenumberingRequiresNewReview() throws {
        let f = try UsageModelFixture.make(owner: self); let model = f.model()
        let review = try model.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID)
        try model.selectProjectDocuments([f.documents[0].id, f.documents[2].id, f.documents[1].id], conversationID: f.activeID, profileID: f.profileID)
        let before = try model.makeBackup()
        assertChangedReferences { try model.deleteReviewedProjectDocuments(review) }
        assertUnchanged(model, before: before)
    }

    @MainActor func testUnrelatedBookmarkAndDocumentEditsDoNotInvalidateReview() throws {
        let f = try UsageModelFixture.make(owner: self); let model = f.model()
        let review = try model.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID)
        let message = try XCTUnwrap(model.conversations.first { $0.id == f.activeID }?.messages.last)
        try model.updateBookmarkNote(.init(conversationID: f.activeID, messageID: message.id), note: "检查期间的新收藏备注")
        _ = try model.saveProjectDocument(id: f.documents[3].id, projectID: f.projectID, title: "未选资料更新", body: "保留这个独立更新", profileID: f.profileID)
        let before = try model.makeBackup()
        try model.deleteReviewedProjectDocuments(review)
        let after = try model.makeBackup()
        XCTAssertEqual(after.conversations.map(\.messages), before.conversations.map(\.messages))
        XCTAssertEqual(model.projects.first { $0.id == f.projectID }?.documents.first { $0.id == f.documents[3].id }?.body, "保留这个独立更新")
        XCTAssertFalse(model.projects.first { $0.id == f.projectID }!.documents.contains { $0.id == f.documents[0].id })
    }

    @MainActor func testSelectedDocumentEditRejectsOldReviewBeforeDeletingAnyDocument() throws {
        let f = try UsageModelFixture.make(owner: self); let model = f.model()
        let review = try model.reviewProjectDocumentDeletion([f.documents[0], f.documents[1]], projectID: f.projectID, profileID: f.profileID)
        _ = try model.saveProjectDocument(id: f.documents[0].id, projectID: f.projectID, title: "修改后的所选资料", body: "需要重新检查", profileID: f.profileID)
        let before = try model.makeBackup()
        XCTAssertThrowsError(try model.deleteReviewedProjectDocuments(review))
        assertUnchanged(model, before: before)
    }

    @MainActor func testStaleProfileAndDissolvedProjectBlockQueriesReviewAndDeletion() throws {
        let f = try UsageModelFixture.make(owner: self); let model = f.model()
        let review = try model.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID)
        model.selectProfile(f.otherProfileID)
        XCTAssertTrue(model.projectDocumentConversations(projectID: f.projectID, profileID: f.profileID).isEmpty)
        XCTAssertThrowsError(try model.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID))
        let foreignBefore = try model.makeBackup()
        XCTAssertThrowsError(try model.deleteReviewedProjectDocuments(review))
        assertUnchanged(model, before: foreignBefore)
        model.selectProfile(f.profileID)
        try model.deleteProject(f.projectID, profileID: f.profileID)
        let dissolvedBefore = try model.makeBackup()
        XCTAssertTrue(model.projectDocumentConversations(projectID: f.projectID, profileID: f.profileID).isEmpty)
        XCTAssertThrowsError(try model.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID))
        XCTAssertThrowsError(try model.deleteReviewedProjectDocuments(review))
        assertUnchanged(model, before: dissolvedBefore)
    }

    @MainActor func testSuccessfulReviewedDeletionPersistsAndPreservesUnselectedOrderMessagesAndDrafts() throws {
        let f = try UsageModelFixture.make(owner: self); let model = f.model()
        model.draft = "保留进行中的草稿"
        model.select(f.archivedID); model.draft = "保留归档草稿"; model.select(f.activeID)
        let review = try model.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID)
        let before = try model.makeBackup(); let selectedID = model.selectedID
        try model.deleteReviewedProjectDocuments(review)
        let after = try model.makeBackup()
        XCTAssertEqual(after.conversations.map(\.messages), before.conversations.map(\.messages))
        XCTAssertEqual(after.conversations.map(\.workspace), before.conversations.map(\.workspace))
        XCTAssertEqual(after.conversations.map(\.updatedAt), before.conversations.map(\.updatedAt))
        XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(after.images, before.images)
        XCTAssertEqual(model.selectedID, selectedID); XCTAssertEqual(model.draft, "保留进行中的草稿")
        XCTAssertEqual(after.conversations.first { $0.id == f.activeID }?.referenceDocumentIDs, [f.documents[2].id, f.documents[1].id])
        XCTAssertEqual(after.conversations.first { $0.id == f.archivedID }?.referenceDocumentIDs, [f.documents[1].id])
        XCTAssertEqual(after.conversations.first { $0.id == f.trashID }?.referenceDocumentIDs, [f.documents[2].id])
        for id in [f.otherProjectConversationID, f.otherProfileConversationID] {
            XCTAssertEqual(after.conversations.first { $0.id == id }, before.conversations.first { $0.id == id })
        }
        let reopened = f.model(); XCTAssertFalse(reopened.needsRecovery)
        XCTAssertEqual(try reopened.makeBackup().profiles, after.profiles)
        XCTAssertEqual(try reopened.makeBackup().conversations, after.conversations)
        XCTAssertEqual(try reopened.makeBackup().drafts, after.drafts)
        XCTAssertEqual(try reopened.makeBackup().version, 7)
    }

    @MainActor func testRecoveryStateHidesUsageAndBlocksReviewAndReviewedDeletion() throws {
        let f = try UsageModelFixture.make(owner: self); let healthy = f.model()
        let review = try healthy.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID)
        let url = f.directory.appendingPathComponent("conversations.json")
        let unreadable = Data("not a valid conversation archive".utf8)
        try unreadable.write(to: url, options: .atomic)
        let recovering = f.model(); XCTAssertTrue(recovering.needsRecovery)
        XCTAssertTrue(recovering.projectDocumentConversations(projectID: f.projectID, profileID: f.profileID).isEmpty)
        XCTAssertThrowsError(try recovering.reviewProjectDocumentDeletion([f.documents[0]], projectID: f.projectID, profileID: f.profileID))
        XCTAssertThrowsError(try recovering.deleteReviewedProjectDocuments(review))
        XCTAssertEqual(try Data(contentsOf: url), unreadable)
    }

    @MainActor func testReviewRejectsEmptyMissingAndForeignSnapshotsAndSupportsUnreferencedDeletion() throws {
        let f = try UsageModelFixture.make(owner: self); let model = f.model()
        let before = try model.makeBackup()
        XCTAssertThrowsError(try model.reviewProjectDocumentDeletion([], projectID: f.projectID, profileID: f.profileID))
        XCTAssertThrowsError(try model.reviewProjectDocumentDeletion([.init(title: "失联资料", body: "未保存")], projectID: f.projectID, profileID: f.profileID))
        XCTAssertThrowsError(try model.reviewProjectDocumentDeletion([f.documents[1]], projectID: f.otherProjectID, profileID: f.profileID))
        XCTAssertTrue(model.projectDocumentConversations(projectID: UUID(), profileID: f.profileID).isEmpty)
        assertUnchanged(model, before: before)
        let review = try model.reviewProjectDocumentDeletion([f.documents[3]], projectID: f.projectID, profileID: f.profileID)
        XCTAssertTrue(review.references.isEmpty)
        try model.deleteReviewedProjectDocuments(review)
        XCTAssertEqual(try model.makeBackup().conversations, before.conversations)
        XCTAssertFalse(model.projects.first { $0.id == f.projectID }!.documents.contains { $0.id == f.documents[3].id })
    }

    @MainActor private func assertChangedReferences(_ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            guard let usageError = error as? ProjectDocumentUsageError else {
                XCTFail("Expected changedReferences, received \(error)", file: file, line: line); return
            }
            guard case .changedReferences = usageError else {
                XCTFail("Expected changedReferences, received \(usageError)", file: file, line: line); return
            }
        }
    }
    @MainActor private func assertUnchanged(_ model: AppModel, before: BackupArchive, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let after = try model.makeBackup()
            XCTAssertEqual(after.profiles, before.profiles, file: file, line: line)
            XCTAssertEqual(after.conversations, before.conversations, file: file, line: line)
            XCTAssertEqual(after.drafts, before.drafts, file: file, line: line)
        } catch { XCTFail("Cannot inspect saved state: \(error)", file: file, line: line) }
    }
}

@MainActor private struct UsageModelFixture {
    let defaults: UserDefaults
    let directory: URL
    let profileID: UUID
    let otherProfileID: UUID
    let projectID: UUID
    let otherProjectID: UUID
    let documents: [ProjectDocument]
    let activeID: UUID
    let archivedID: UUID
    let trashID: UUID
    let unreferencedID: UUID
    let otherProjectConversationID: UUID
    let otherProfileConversationID: UUID

    static func make(owner: XCTestCase) throws -> Self {
        let suite = "HermesUsageModel.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1792600000)
        let docs = (0..<4).map { ProjectDocument(title: "资料\($0 + 1)", body: "完整正文\($0 + 1)", createdAt: date, updatedAt: date.addingTimeInterval(Double(-$0))) }
        let source = LocalProject(name: "引用检查项目", summary: "统计当前保存的引用", instructions: "准确标注来源", createdAt: date, updatedAt: date, knowledgeDocuments: docs)
        // Deliberately repeat a document UUID in a different project and profile to exercise scope isolation.
        let other = LocalProject(name: "其他项目", summary: "", instructions: "", createdAt: date, updatedAt: date, knowledgeDocuments: [docs[0]])
        let profile = ConnectionProfile(name: "引用检查连接", serverURL: "https://usage-model.hermes.test", model: "hermes-agent", localProjects: [source, other])
        let foreign = ConnectionProfile(name: "其他连接", serverURL: "https://other-usage-model.hermes.test", model: "hermes-agent", localProjects: [source])
        func record(_ title: String, profileID: UUID, projectID: UUID, refs: [UUID]?, archived: Bool = false, trashed: Bool = false) -> Conversation {
            Conversation(title: title, messages: [.init(role: .user, content: "原始问题", createdAt: date), .init(role: .assistant, content: "应当保留的回复", createdAt: date, bookmark: .init(createdAt: date, note: "原收藏备注"))], updatedAt: date, profileID: profileID,
                workspace: .init(archived: archived, trashedAt: trashed ? date : nil), projectID: projectID, referenceDocumentIDs: refs)
        }
        let active = record("进行中的研究", profileID: profile.id, projectID: source.id, refs: [docs[2].id, docs[0].id, docs[1].id])
        let archived = record("已归档的研究", profileID: profile.id, projectID: source.id, refs: [docs[1].id, docs[0].id], archived: true)
        let trash = record("回收站的研究", profileID: profile.id, projectID: source.id, refs: [docs[2].id, docs[0].id], archived: true, trashed: true)
        let unused = record("没有选中资料", profileID: profile.id, projectID: source.id, refs: nil)
        let otherRecord = record("其他项目的引用", profileID: profile.id, projectID: other.id, refs: [docs[0].id])
        let foreignRecord = record("其他连接的引用", profileID: foreign.id, projectID: source.id, refs: [docs[0].id])
        let records = [active, archived, trash, unused, otherRecord, foreignRecord]
        let library = ConnectionLibrary(profiles: [profile, foreign], activeID: profile.id, selectedConversations: [profile.id.uuidString: active.id.uuidString, foreign.id.uuidString: foreignRecord.id.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"))
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("conversations.json"))
        owner.addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return Self(defaults: defaults, directory: directory, profileID: profile.id, otherProfileID: foreign.id, projectID: source.id, otherProjectID: other.id,
            documents: docs, activeID: active.id, archivedID: archived.id, trashID: trash.id, unreferencedID: unused.id, otherProjectConversationID: otherRecord.id, otherProfileConversationID: foreignRecord.id)
    }
    func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UsageModelNetworkGuard.self]
        return AppModel(defaults: defaults, directory: directory, credentials: MemoryCredentials(), sessionConfiguration: configuration)
    }
}

private final class UsageModelNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { XCTFail("引用检查不应联网"); client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
