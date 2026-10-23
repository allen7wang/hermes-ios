import XCTest
import UIKit
@testable import Hermes

final class ProjectReferenceAdditionTests: XCTestCase {
    @MainActor func testAppendPreservesExistingPositionsAndIncomingOrder() throws {
        let f = try AdditionFixture.make(owner: self); let project = f.project
        var conversation = f.records[0]; conversation.referenceDocumentIDs = [f.doc(1), f.doc(0)]
        let original = conversation
        let row = try ProjectReferenceAddition.makeRow(conversation, adding: [f.doc(0), f.doc(3), f.doc(2)], project: project, profileID: f.profileID)
        XCTAssertEqual(row.beforeIDs, [f.doc(1), f.doc(0)])
        XCTAssertEqual(row.afterIDs, [f.doc(1), f.doc(0), f.doc(3), f.doc(2)])
        XCTAssertEqual(row.addedCount, 2); XCTAssertEqual(conversation, original)
    }

    @MainActor func testEmptyAndDuplicateIncomingAndMalformedExistingSelectionsAreRejected() throws {
        let f = try AdditionFixture.make(owner: self)
        for incoming in [[], [f.doc(2), f.doc(2)], [UUID()]] {
            XCTAssertThrowsError(try ProjectReferenceAddition.makeRow(f.records[0], adding: incoming, project: f.project, profileID: f.profileID))
        }
        for existing in [[f.doc(0), f.doc(0)], [UUID()], f.project.documents.map(\.id)] {
            var record = f.records[0]; record.referenceDocumentIDs = existing
            XCTAssertThrowsError(try ProjectReferenceAddition.makeRow(record, adding: [f.doc(2)], project: f.project, profileID: f.profileID))
        }
    }

    @MainActor func testNilSelectionBecomesOrderedReferencesAndAllExistingIsNoOp() throws {
        let f = try AdditionFixture.make(owner: self)
        var record = f.records[0]; record.referenceDocumentIDs = nil
        let row = try ProjectReferenceAddition.makeRow(record, adding: [f.doc(2), f.doc(1)], project: f.project, profileID: f.profileID)
        XCTAssertEqual(row.beforeIDs, []); XCTAssertEqual(row.afterIDs, [f.doc(2), f.doc(1)])
        record.referenceDocumentIDs = [f.doc(1), f.doc(2)]
        let unchanged = try ProjectReferenceAddition.makeRow(record, adding: [f.doc(2), f.doc(1)], project: f.project, profileID: f.profileID)
        XCTAssertFalse(unchanged.hasChanges); XCTAssertEqual(unchanged.addedCount, 0)
    }

    @MainActor func testFiveReferenceLimitAppliesAfterDeduplication() throws {
        let f = try AdditionFixture.make(owner: self)
        var record = f.records[0]; record.referenceDocumentIDs = (0..<4).map(f.doc)
        let row = try ProjectReferenceAddition.makeRow(record, adding: [f.doc(3), f.doc(4)], project: f.project, profileID: f.profileID)
        XCTAssertEqual(row.afterIDs.count, 5)
        XCTAssertThrowsError(try ProjectReferenceAddition.makeRow(record, adding: [f.doc(4), f.doc(5)], project: f.project, profileID: f.profileID))
    }

    @MainActor func testFiftyThousandCharactersIsAllowedButOneMoreIsRejected() throws {
        let f = try AdditionFixture.make(owner: self)
        var project = f.project
        project.documents[0].body = String(repeating: "字", count: 20_000)
        project.documents[1].body = String(repeating: "字", count: 15_000)
        project.documents[2].body = String(repeating: "字", count: 15_000)
        XCTAssertEqual(try ProjectReferenceAddition.makeRow(f.records[0], adding: [f.doc(1), f.doc(2)], project: project, profileID: f.profileID).afterIDs.count, 3)
        project.documents[2].body += "多"
        XCTAssertThrowsError(try ProjectReferenceAddition.makeRow(f.records[0], adding: [f.doc(1), f.doc(2)], project: project, profileID: f.profileID))
    }

    @MainActor func testPureRowsRejectForeignOrUnassignedConversations() throws {
        let f = try AdditionFixture.make(owner: self)
        for record in f.records.suffix(2) {
            XCTAssertThrowsError(try ProjectReferenceAddition.makeRow(record, adding: [f.doc(2)], project: f.project, profileID: f.profileID))
        }
        var record = f.records[0]; record.projectID = nil
        XCTAssertThrowsError(try ProjectReferenceAddition.makeRow(record, adding: [f.doc(2)], project: f.project, profileID: f.profileID))
    }

    @MainActor func testPreviewIsReadOnlyAndSnapshotsBothChangedAndUnchangedRows() throws {
        let f = try AdditionFixture.make(owner: self); let model = f.model()
        let files = try f.files(); let before = try model.makeBackup()
        let review = try f.review(model, conversations: [f.activeID, f.archivedID, f.trashID, f.unchangedID])
        XCTAssertEqual(review.rows.count, 4); XCTAssertEqual(review.changedCount, 3)
        XCTAssertEqual(review.addingDocuments.map(\.id), [f.doc(2), f.doc(1)])
        XCTAssertEqual(Set(review.documents.map(\.id)), Set([f.doc(0), f.doc(1), f.doc(2)]))
        XCTAssertEqual(review.rows.first { $0.id == f.trashID }?.status, .trash)
        XCTAssertFalse(try XCTUnwrap(review.rows.first { $0.id == f.unchangedID }).hasChanges)
        XCTAssertEqual(try f.files(), files); XCTAssertEqual(try model.makeBackup().conversations, before.conversations)
        XCTAssertEqual(model.selectedID, f.activeID); XCTAssertEqual(model.draft, "尚未发送的草稿")
    }

    @MainActor func testApplyPersistsOnlyReferencesAcrossMixedStatesAndBackupRoundTrip() throws {
        let f = try AdditionFixture.make(owner: self); let model = f.model()
        let before = try model.makeBackup()
        let review = try f.review(model, conversations: [f.activeID, f.archivedID, f.trashID, f.unchangedID])
        try model.applyProjectReferenceAddition(review)
        let after = try model.makeBackup()
        for original in before.conversations {
            var expected = original
            if let row = review.rows.first(where: { $0.id == original.id }), row.hasChanges { expected.referenceDocumentIDs = row.afterIDs }
            XCTAssertEqual(after.conversations.first { $0.id == original.id }, expected)
        }
        XCTAssertEqual(after.profiles, before.profiles); XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(after.images, before.images)
        XCTAssertEqual(model.selectedID, f.activeID); XCTAssertEqual(model.draft, "尚未发送的草稿")
        let reopened = f.model()
        XCTAssertEqual(try reopened.makeBackup().conversations, after.conversations)
        XCTAssertEqual(reopened.draft, model.draft); XCTAssertEqual(reopened.selectedID, model.selectedID)
        XCTAssertEqual(after.version, 7)
        let decoded = try BackupArchive.decode(after.encoded())
        XCTAssertEqual(decoded.conversations, after.conversations); XCTAssertEqual(decoded.images, before.images)
    }

    @MainActor func testMissingSelectionsUnknownDocumentsAndAllNoOpBatchesDoNotWrite() throws {
        let f = try AdditionFixture.make(owner: self); let model = f.model(); let files = try f.files()
        XCTAssertThrowsError(try model.previewProjectReferenceAddition(documentIDs: [], conversationIDs: [f.activeID], projectID: f.projectID, profileID: f.profileID))
        XCTAssertThrowsError(try f.review(model, conversations: []))
        XCTAssertThrowsError(try model.previewProjectReferenceAddition(documentIDs: [UUID()], conversationIDs: [f.activeID], projectID: f.projectID, profileID: f.profileID))
        XCTAssertThrowsError(try f.review(model, conversations: [f.unchangedID])) { error in
            guard case ProjectReferenceAdditionError.alreadyReferenced = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try f.files(), files)
    }

    @MainActor func testOnlyExplicitSubsetChangesAndUnselectedEditsArePreserved() throws {
        let f = try AdditionFixture.make(owner: self); let model = f.model(); let review = try f.review(model)
        try model.selectProjectDocuments([f.doc(4), f.doc(3)], conversationID: f.unselectedID, profileID: f.profileID)
        model.rename(f.plainID, to: "未纳入本次范围的新标题")
        let before = try model.makeBackup()
        try model.applyProjectReferenceAddition(review)
        for record in before.conversations where record.id != f.activeID {
            XCTAssertEqual(try model.makeBackup().conversations.first { $0.id == record.id }, record)
        }
    }

    @MainActor func testStaleFullReferenceOrderIsRejectedWithoutPartialSave() throws {
        let f = try AdditionFixture.make(owner: self); let model = f.model()
        let review = try f.review(model, conversations: [f.activeID, f.archivedID])
        try model.selectProjectDocuments([f.doc(1), f.doc(0)], conversationID: f.archivedID, profileID: f.profileID)
        try f.assertRejected(model, review)
    }

    @MainActor func testChangedTitleArchiveOrTrashStatusInvalidatesReview() throws {
        for change in 0..<3 {
            let f = try AdditionFixture.make(owner: self); let model = f.model(); let review = try f.review(model)
            if change == 0 { model.rename(f.activeID, to: "检查后改名") }
            if change == 1 { try model.setArchived([f.activeID], archived: true) }
            if change == 2 { try model.deleteConversations([f.activeID]) }
            try f.assertRejected(model, review)
        }
    }

    @MainActor func testMovedOrPermanentlyDeletedConversationCannotApplyOldPlan() throws {
        for remove in [false, true] {
            let f = try AdditionFixture.make(owner: self); let model = f.model(); let review = try f.review(model)
            if remove {
                try model.deleteConversations([f.activeID]); try model.permanentlyDeleteConversations([f.activeID])
            } else { try model.assignConversations([f.activeID], toProject: f.otherProjectID, profileID: f.profileID) }
            try f.assertRejected(model, review)
        }
    }

    @MainActor func testEditingNewOrExistingInvolvedDocumentInvalidatesReview() throws {
        for index in [0, 2] {
            let f = try AdditionFixture.make(owner: self); let model = f.model(); let review = try f.review(model)
            _ = try model.saveProjectDocument(id: f.doc(index), projectID: f.projectID,
                title: f.project.documents[index].title, body: "检查后更新正文", profileID: f.profileID)
            try f.assertRejected(model, review)
        }
    }

    @MainActor func testUnrelatedDocumentAndBookmarkEditsSurviveApply() throws {
        let f = try AdditionFixture.make(owner: self); let model = f.model(); let review = try f.review(model)
        _ = try model.saveProjectDocument(id: f.doc(5), projectID: f.projectID, title: "未涉及的资料", body: "更新后的独立内容", profileID: f.profileID)
        let message = try XCTUnwrap(model.selectedConversation?.messages.last)
        try model.updateBookmarkNote(.init(conversationID: f.activeID, messageID: message.id), note: "检查后更新收藏")
        let before = try model.makeBackup()
        try model.applyProjectReferenceAddition(review)
        XCTAssertEqual(model.profiles, before.profiles)
        XCTAssertEqual(model.selectedConversation?.messages, before.conversations.first { $0.id == f.activeID }?.messages)
    }

    @MainActor func testExactProfileProjectScopeAndSwitchingConnectionsAreEnforced() throws {
        let f = try AdditionFixture.make(owner: self); let model = f.model(); let review = try f.review(model)
        for id in [f.records[6].id, f.records[7].id, UUID()] { XCTAssertThrowsError(try f.review(model, conversations: [id])) }
        XCTAssertThrowsError(try model.previewProjectReferenceAddition(documentIDs: [f.doc(2)], conversationIDs: [f.activeID], projectID: f.otherProjectID, profileID: f.profileID))
        model.selectProfile(f.otherProfileID); try f.assertRejected(model, review)
        model.selectProfile(f.profileID); try model.applyProjectReferenceAddition(review)
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, [f.doc(0), f.doc(2), f.doc(1)])
    }

    @MainActor func testSingleOverBudgetConversationRejectsEntireBatchAndNamesTheProblem() throws {
        let f = try AdditionFixture.make(owner: self, overBudget: true); let model = f.model()
        let files = try f.files()
        _ = try model.previewProjectReferenceAddition(documentIDs: [f.doc(2)], conversationIDs: [f.activeID], projectID: f.projectID, profileID: f.profileID)
        XCTAssertThrowsError(try model.previewProjectReferenceAddition(documentIDs: [f.doc(2)], conversationIDs: [f.activeID, f.archivedID], projectID: f.projectID, profileID: f.profileID)) { error in
            XCTAssertTrue(error.localizedDescription.contains("已归档"))
        }
        XCTAssertEqual(try f.files(), files)
    }

    @MainActor func testWriteFailurePreservesPublishedRecordsSelectionDraftsAndImages() throws {
        let f = try AdditionFixture.make(owner: self); let model = f.model()
        let review = try f.review(model, conversations: [f.activeID, f.trashID]); let before = try model.makeBackup()
        let url = f.directory.appendingPathComponent("conversations.json"); let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.applyProjectReferenceAddition(review))
        let after = try model.makeBackup()
        XCTAssertEqual(after.conversations, before.conversations); XCTAssertEqual(after.profiles, before.profiles)
        XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(after.images, before.images)
        XCTAssertEqual(model.selectedID, f.activeID); XCTAssertEqual(model.draft, "尚未发送的草稿")
        try FileManager.default.removeItem(at: url); try data.write(to: url, options: .atomic)
        XCTAssertEqual(try f.model().makeBackup().conversations, before.conversations)
    }

    @MainActor func testRecoveryRejectsPreviewAndApplyWithoutTouchingUnreadableData() throws {
        let f = try AdditionFixture.make(owner: self); let review = try f.review(f.model())
        let invalid = Data("{invalid".utf8); try invalid.write(to: f.directory.appendingPathComponent("drafts.json"))
        let model = f.model(); XCTAssertTrue(model.needsRecovery)
        let files = try f.files()
        XCTAssertThrowsError(try f.review(model)); XCTAssertThrowsError(try model.applyProjectReferenceAddition(review))
        XCTAssertEqual(try f.files(), files)
    }

    @MainActor func testNextContextUsesNewOrderAndRepeatApplyDoesNotWriteAgain() throws {
        let f = try AdditionFixture.make(owner: self); let model = f.model()
        let previous = try model.previewNextRequest(model.draft, hasImage: false, expectedDraftKey: model.draftKey)
        let review = try f.review(model); try model.applyProjectReferenceAddition(review)
        let next = try model.previewNextRequest(model.draft, hasImage: false, expectedDraftKey: model.draftKey)
        XCTAssertEqual(previous.plan.referenceDocuments.map(\.id), [f.doc(0)])
        XCTAssertEqual(next.plan.referenceDocuments.map(\.id), [f.doc(0), f.doc(2), f.doc(1)])
        XCTAssertTrue(next.plan.effectiveSystemPrompt.contains("[资料2] " + f.project.documents[2].title))
        XCTAssertEqual(next.plan.messages.map(\.content), previous.plan.messages.map(\.content))
        XCTAssertEqual(next.plan.messages.map(\.role), previous.plan.messages.map(\.role))
        try f.assertRejected(model, review)
    }

    @MainActor func testBusySendBlocksReferenceChanges() async throws {
        let f = try AdditionFixture.make(owner: self); let model = f.model(pendingSend: true); let review = try f.review(model)
        XCTAssertTrue(model.send("测试忙碌保护")); XCTAssertTrue(model.isSending)
        let before = model.selectedConversation?.referenceDocumentIDs
        XCTAssertThrowsError(try f.review(model)); XCTAssertThrowsError(try model.applyProjectReferenceAddition(review))
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, before)
        model.cancelSend()
        for _ in 0..<100 where model.isSending { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isSending)
    }
}

@MainActor struct AdditionFixture {
    let defaults: UserDefaults
    let directory: URL
    let profileID: UUID
    let otherProfileID: UUID
    let project: LocalProject
    let otherProjectID: UUID
    let records: [Conversation]
    var projectID: UUID { project.id }
    var activeID: UUID { records[0].id }
    var archivedID: UUID { records[1].id }
    var trashID: UUID { records[2].id }
    var unchangedID: UUID { records[3].id }
    var unselectedID: UUID { records[4].id }
    var plainID: UUID { records[5].id }
    func doc(_ index: Int) -> UUID { project.documents[index].id }

    static func make(owner: XCTestCase, overBudget: Bool = false) throws -> Self {
        let suite = "HermesReferenceAddition.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        owner.addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_792_600_000)
        let titles = ["发布约定 · 保留原有引用位置", "验收清单 · 新增回归与交付边界", "用户访谈 · 新一轮发现与后续行动", "研究笔记", "其他对话的资料", "独立参考"]
        let documents = titles.enumerated().map { index, title in
            ProjectDocument(title: title, body: overBudget && index < 3 ? String(repeating: "字", count: [20_000, 15_000, 15_001][index]) : "# \(title)\n\n此处是完整示例正文，检查后只更新所选对话的后续资料引用。", createdAt: date, updatedAt: date.addingTimeInterval(Double(-index)))
        }
        let project = LocalProject(name: "资料分发示例项目", summary: "检查后批量添加引用", instructions: "用中文回答并标注资料编号", createdAt: date, updatedAt: date, knowledgeDocuments: documents)
        let other = LocalProject(name: "其他项目", summary: "", instructions: "", knowledgeDocuments: documents)
        let profile = ConnectionProfile(name: "当前示例连接", serverURL: "https://addition.hermes.test", model: "hermes-agent", localProjects: [project, other])
        let foreign = ConnectionProfile(name: "其他连接", serverURL: "https://foreign-addition.hermes.test", model: "hermes-agent", localProjects: [project])
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let imageID = try ImageAttachmentStore.save(try XCTUnwrap(image.jpegData(compressionQuality: 0.8)), directory: directory.appendingPathComponent("Attachments"))
        func record(_ title: String, references: [UUID], archived: Bool = false, trash: Bool = false,
                    profileID: UUID? = nil, projectID: UUID? = nil) -> Conversation {
            Conversation(title: title, messages: [.init(role: .user, content: "原问题与 [资料1]", createdAt: date, imageID: imageID),
                .init(role: .assistant, content: "历史回答保持原样", createdAt: date, bookmark: .init(createdAt: date, note: "保留收藏备注"))],
                updatedAt: date, profileID: profileID ?? profile.id, pinned: true,
                workspace: .init(tags: ["工作"], archived: archived,
                    configuration: .init(systemPrompt: "保留对话指令", contextTurns: 3), trashedAt: trash ? date : nil),
                projectID: projectID ?? project.id, referenceDocumentIDs: references.isEmpty ? nil : references)
        }
        let records = [record("进行中 · 本周交付讨论", references: [documents[0].id]),
            record("已归档 · 上一轮验收讨论", references: [documents[0].id, documents[1].id], archived: true),
            record("回收站 · 恢复后继续使用资料", references: [], archived: true, trash: true),
            record("已具备全部资料 · 无需改动", references: overBudget ? [documents[2].id] : [documents[2].id, documents[1].id, documents[0].id]),
            record("未选中的对话", references: [documents[4].id]), record("尚未引用资料", references: []),
            record("其他项目", references: [documents[0].id], projectID: other.id),
            record("其他连接", references: [documents[0].id], profileID: foreign.id)]
        let library = ConnectionLibrary(profiles: [profile, foreign], activeID: profile.id, selectedConversations: [profile.id.uuidString: records[0].id.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"))
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("conversations.json"))
        let drafts = Dictionary(uniqueKeysWithValues: records.map { (DraftStore.localKey(profileID: $0.profileID!, conversationID: $0.id), "尚未发送的草稿") })
        try JSONEncoder().encode(drafts).write(to: directory.appendingPathComponent("drafts.json"))
        return Self(defaults: defaults, directory: directory, profileID: profile.id, otherProfileID: foreign.id, project: project,
            otherProjectID: other.id, records: records)
    }
    func model(pendingSend: Bool = false) -> AppModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = pendingSend ? [AdditionPendingProtocol.self] : [AdditionNetworkGuard.self]
        let keys = MemoryCredentials(); keys.values["connection-\(profileID.uuidString)"] = "isolated-test-key"
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: config)
    }
    func review(_ model: AppModel, conversations: Set<UUID>? = nil) throws -> ProjectReferenceAdditionReview {
        try model.previewProjectReferenceAddition(documentIDs: [doc(2), doc(1)], conversationIDs: conversations ?? [activeID], projectID: projectID, profileID: profileID)
    }
    func files() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in entries where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[url.path.replacingOccurrences(of: directory.path, with: "")] = try Data(contentsOf: url)
        }
        return result
    }
    func assertRejected(_ model: AppModel, _ review: ProjectReferenceAdditionReview, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try model.makeBackup(); let files = try files(); let selected = model.selectedID; let draft = model.draft
        XCTAssertThrowsError(try model.applyProjectReferenceAddition(review), file: file, line: line)
        let after = try model.makeBackup()
        XCTAssertEqual(after.conversations, before.conversations, file: file, line: line)
        XCTAssertEqual(after.profiles, before.profiles, file: file, line: line)
        XCTAssertEqual(after.drafts, before.drafts, file: file, line: line); XCTAssertEqual(after.images, before.images, file: file, line: line)
        XCTAssertEqual(try self.files(), files, file: file, line: line)
        XCTAssertEqual(model.selectedID, selected, file: file, line: line); XCTAssertEqual(model.draft, draft, file: file, line: line)
    }
}

private final class AdditionNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { XCTFail("Reference addition must not send requests"); client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
private final class AdditionPendingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
