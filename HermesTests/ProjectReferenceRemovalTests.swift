import XCTest
@testable import Hermes

final class ProjectReferenceRemovalTests: XCTestCase {
    @MainActor func testRemovalKeepsRetainedRelativeOrderRegardlessOfInputOrder() throws {
        let f = try RemovalFixture.make(owner: self)
        var record = f.records[0]; record.referenceDocumentIDs = [f.doc(3), f.doc(0), f.doc(2), f.doc(1)]
        let before = record
        let row = try ProjectReferenceRemoval.makeRow(record, removing: [f.doc(1), f.doc(0)], project: f.project, profileID: f.profileID)
        XCTAssertEqual(row.beforeIDs, before.referenceDocumentIDs)
        XCTAssertEqual(row.afterIDs, [f.doc(3), f.doc(2)]); XCTAssertEqual(row.removedCount, 2)
        XCTAssertEqual(record, before)
    }

    @MainActor func testNilAndEmptyReferencesAreNoOpWhileRemovingAllProducesEmptySelection() throws {
        let f = try RemovalFixture.make(owner: self)
        let emptySelections: [[UUID]?] = [nil, []]
        for refs in emptySelections {
            var record = f.records[0]; record.referenceDocumentIDs = refs
            let row = try ProjectReferenceRemoval.makeRow(record, removing: [f.doc(0)], project: f.project, profileID: f.profileID)
            XCTAssertFalse(row.hasChanges); XCTAssertEqual(row.removedCount, 0)
        }
        let row = try ProjectReferenceRemoval.makeRow(f.records[0], removing: [f.doc(0), f.doc(1), f.doc(2)], project: f.project, profileID: f.profileID)
        XCTAssertTrue(row.hasChanges); XCTAssertEqual(row.afterIDs, [])
    }

    @MainActor func testInvalidRemovalAndMalformedSavedReferencesAreRejected() throws {
        let f = try RemovalFixture.make(owner: self)
        for ids in [[], [f.doc(0), f.doc(0)], [UUID()]] {
            XCTAssertThrowsError(try ProjectReferenceRemoval.makeRow(f.records[0], removing: ids, project: f.project, profileID: f.profileID))
        }
        for ids in [[f.doc(0), f.doc(0)], [UUID()], f.project.documents.map(\.id)] {
            var record = f.records[0]; record.referenceDocumentIDs = ids
            XCTAssertThrowsError(try ProjectReferenceRemoval.makeRow(record, removing: [f.doc(0)], project: f.project, profileID: f.profileID))
        }
    }

    @MainActor func testFullLibraryRemovalAllowsTwentyDocumentsAndTwoHundredThousandCharacters() throws {
        let f = try RemovalFixture.make(owner: self)
        let model = f.model()
        // Six existing documents already exceed a single request's count; fill the library to its real limit.
        for index in 6..<20 {
            _ = try model.saveProjectDocument(id: nil, projectID: f.projectID, title: "资料 \(index)", body: "正文", profileID: f.profileID)
        }
        let project = try XCTUnwrap(model.projects.first { $0.id == f.projectID })
        XCTAssertEqual(project.documents.count, 20)
        let review = try model.previewProjectReferenceRemoval(documentIDs: project.documents.map(\.id), conversationIDs: [f.activeID, f.archivedID], projectID: f.projectID, profileID: f.profileID)
        XCTAssertEqual(review.removingDocuments.count, 20)
        try model.applyProjectReferenceRemoval(review)
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, [])
        XCTAssertEqual(model.projects.first { $0.id == f.projectID }?.documents, project.documents)
        var full = project
        full.documents = full.documents.map { var document = $0; document.body = String(repeating: "字", count: 10_000); return document }
        var record = f.records[0]; record.referenceDocumentIDs = Array(full.documents.prefix(5).map(\.id))
        let row = try ProjectReferenceRemoval.makeRow(record, removing: full.documents.map(\.id), project: full, profileID: f.profileID)
        XCTAssertEqual(row.removedCount, 5); XCTAssertEqual(row.afterIDs, [])
    }

    @MainActor func testPreviewCapturesMixedStatesNoOpRowsAndAllInvolvedDocumentsWithoutWriting() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model(); let files = try f.files()
        let review = try f.removalReview(model, conversations: [f.activeID, f.archivedID, f.trashID, f.plainID])
        XCTAssertEqual(review.rows.count, 4); XCTAssertEqual(review.changedCount, 3)
        XCTAssertEqual(Set(review.documents.map(\.id)), Set([f.doc(0), f.doc(1), f.doc(2)]))
        XCTAssertEqual(review.rows.first { $0.id == f.trashID }?.status, .trash)
        XCTAssertFalse(try XCTUnwrap(review.rows.first { $0.id == f.plainID }).hasChanges)
        XCTAssertEqual(try f.files(), files); XCTAssertEqual(model.selectedID, f.activeID)
        XCTAssertEqual(model.draft, "尚未发送的草稿")
    }

    @MainActor func testAtomicApplyPersistsOnlySelectedReferencesAndBackupRoundTrips() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model(); let before = try model.makeBackup()
        let review = try f.removalReview(model, conversations: [f.activeID, f.archivedID, f.trashID, f.plainID])
        try model.applyProjectReferenceRemoval(review)
        let after = try model.makeBackup()
        for original in before.conversations {
            var expected = original
            if let row = review.rows.first(where: { $0.id == original.id }), row.hasChanges { expected.referenceDocumentIDs = row.afterIDs }
            XCTAssertEqual(after.conversations.first { $0.id == original.id }, expected)
        }
        XCTAssertEqual(after.profiles, before.profiles); XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(after.images, before.images)
        XCTAssertEqual(f.model().selectedConversation?.referenceDocumentIDs, [f.doc(2)])
        XCTAssertEqual(after.version, 7)
        let archive = try BackupArchive.decode(after.encoded())
        XCTAssertEqual(archive.conversations, after.conversations)
        let destination = try RemovalFixture.make(owner: self); let restored = destination.model()
        _ = try restored.importBackup(archive)
        let profile = try XCTUnwrap(restored.profiles.first { $0.name == "当前示例连接（已导入）" })
        restored.selectProfile(profile.id)
        let imported = try XCTUnwrap(restored.conversations.first { $0.title == f.records[0].title })
        let importedProject = try XCTUnwrap(restored.projects.first { $0.id == imported.projectID })
        let retained = try ProjectDocument.selected(ids: imported.referenceDocumentIDs ?? [], from: importedProject)
        XCTAssertEqual(retained.map(\.title), [f.project.documents[2].title])
        XCTAssertEqual(imported.messages.map(\.content), f.records[0].messages.map(\.content))
        XCTAssertNotNil(imported.messages.first?.imageID)
    }

    @MainActor func testMissingSelectionsUnknownDocumentsAndAllNoOpBatchesDoNotWrite() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model(); let files = try f.files()
        XCTAssertThrowsError(try model.previewProjectReferenceRemoval(documentIDs: [], conversationIDs: [f.activeID], projectID: f.projectID, profileID: f.profileID))
        XCTAssertThrowsError(try f.removalReview(model, conversations: []))
        XCTAssertThrowsError(try model.previewProjectReferenceRemoval(documentIDs: [UUID()], conversationIDs: [f.activeID], projectID: f.projectID, profileID: f.profileID))
        XCTAssertThrowsError(try f.removalReview(model, conversations: [f.plainID])) { error in
            guard case ProjectReferenceRemovalError.notReferenced = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try f.files(), files)
    }

    @MainActor func testOnlyExplicitSubsetChangesWhileUnselectedEditsSurvive() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model(); let review = try f.removalReview(model)
        try model.selectProjectDocuments([f.doc(4), f.doc(3)], conversationID: f.unselectedID, profileID: f.profileID)
        model.rename(f.plainID, to: "未纳入本次范围的新标题")
        let before = try model.makeBackup(); try model.applyProjectReferenceRemoval(review)
        for record in before.conversations where record.id != f.activeID {
            XCTAssertEqual(try model.makeBackup().conversations.first { $0.id == record.id }, record)
        }
    }

    @MainActor func testChangedReferenceOrderRejectsEntireBatch() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model()
        let review = try f.removalReview(model, conversations: [f.activeID, f.archivedID])
        try model.selectProjectDocuments([f.doc(1), f.doc(0)], conversationID: f.archivedID, profileID: f.profileID)
        try f.assertRemovalRejected(model, review)
    }

    @MainActor func testChangedTitleArchiveOrTrashStatusInvalidatesReview() throws {
        for change in 0..<3 {
            let f = try RemovalFixture.make(owner: self); let model = f.model(); let review = try f.removalReview(model)
            if change == 0 { model.rename(f.activeID, to: "检查后改名") }
            if change == 1 { try model.setArchived([f.activeID], archived: true) }
            if change == 2 { try model.deleteConversations([f.activeID]) }
            try f.assertRemovalRejected(model, review)
        }
    }

    @MainActor func testMovedOrPermanentlyDeletedConversationRejectsOldPlan() throws {
        for remove in [false, true] {
            let f = try RemovalFixture.make(owner: self); let model = f.model(); let review = try f.removalReview(model)
            if remove { try model.deleteConversations([f.activeID]); try model.permanentlyDeleteConversations([f.activeID]) }
            else { try model.assignConversations([f.activeID], toProject: f.otherProjectID, profileID: f.profileID) }
            try f.assertRemovalRejected(model, review)
        }
    }

    @MainActor func testEditingRemovedOrRetainedDocumentInvalidatesSnapshot() throws {
        for index in [0, 2] {
            let f = try RemovalFixture.make(owner: self); let model = f.model(); let review = try f.removalReview(model)
            _ = try model.saveProjectDocument(id: f.doc(index), projectID: f.projectID,
                title: f.project.documents[index].title, body: "检查后更新正文", profileID: f.profileID)
            try f.assertRemovalRejected(model, review)
        }
    }

    @MainActor func testUnrelatedDocumentsLatestBookmarksAndPinsArePreserved() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model(); let review = try f.removalReview(model)
        _ = try model.saveProjectDocument(id: f.doc(5), projectID: f.projectID, title: "未涉及的资料", body: "独立更新", profileID: f.profileID)
        let message = try XCTUnwrap(model.selectedConversation?.messages.last)
        try model.updateBookmarkNote(.init(conversationID: f.activeID, messageID: message.id), note: "检查后的收藏备注")
        model.togglePin(f.activeID)
        model.draft = "检查后的新草稿"
        let before = try model.makeBackup(); try model.applyProjectReferenceRemoval(review)
        XCTAssertEqual(model.profiles, before.profiles); XCTAssertEqual(model.draft, "检查后的新草稿")
        var expected = try XCTUnwrap(before.conversations.first { $0.id == f.activeID }); expected.referenceDocumentIDs = [f.doc(2)]
        XCTAssertEqual(model.selectedConversation, expected)
    }

    @MainActor func testExactConnectionProjectAndUnknownConversationAreEnforced() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model(); let files = try f.files()
        for id in [f.records[6].id, f.records[7].id, UUID()] { XCTAssertThrowsError(try f.removalReview(model, conversations: [f.activeID, id])) }
        XCTAssertThrowsError(try model.previewProjectReferenceRemoval(documentIDs: [f.doc(0)], conversationIDs: [f.activeID], projectID: f.otherProjectID, profileID: f.profileID))
        XCTAssertEqual(try f.files(), files)
    }

    @MainActor func testSwitchingConnectionsRejectsReviewAndReturningAllowsFreshState() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model(); let review = try f.removalReview(model)
        model.selectProfile(f.otherProfileID); try f.assertRemovalRejected(model, review)
        model.selectProfile(f.profileID); try model.applyProjectReferenceRemoval(review)
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, [f.doc(2)])
    }

    @MainActor func testProjectRenameInvalidatesDisplayedPlan() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model(); let review = try f.removalReview(model)
        _ = try model.saveProject(id: f.projectID, name: "检查后新名称", summary: f.project.summary, instructions: f.project.instructions, profileID: f.profileID)
        try f.assertRemovalRejected(model, review)
    }

    @MainActor func testWriteFailurePreservesRecordsDraftsImagesAndPublishedState() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model()
        let review = try f.removalReview(model, conversations: [f.activeID, f.trashID]); let before = try model.makeBackup()
        let url = f.directory.appendingPathComponent("conversations.json"); let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.applyProjectReferenceRemoval(review))
        let after = try model.makeBackup()
        XCTAssertEqual(after.conversations, before.conversations); XCTAssertEqual(after.profiles, before.profiles)
        XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(after.images, before.images)
        XCTAssertEqual(model.selectedID, f.activeID); XCTAssertEqual(model.draft, "尚未发送的草稿")
        try FileManager.default.removeItem(at: url); try data.write(to: url, options: .atomic)
        XCTAssertEqual(try f.model().makeBackup().conversations, before.conversations)
    }

    @MainActor func testRecoveryRejectsPreviewAndApplyWithoutTouchingUnreadableData() throws {
        let f = try RemovalFixture.make(owner: self); let review = try f.removalReview(f.model())
        try Data("{invalid".utf8).write(to: f.directory.appendingPathComponent("drafts.json"))
        let model = f.model(); XCTAssertTrue(model.needsRecovery); let files = try f.files()
        XCTAssertThrowsError(try f.removalReview(model)); XCTAssertThrowsError(try model.applyProjectReferenceRemoval(review))
        XCTAssertEqual(try f.files(), files)
    }

    @MainActor func testNextContextRenumbersRetainedDocumentsAndRepeatApplyDoesNotWrite() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model()
        let previous = try model.previewNextRequest(model.draft, hasImage: false, expectedDraftKey: model.draftKey)
        try model.applyProjectReferenceRemoval(f.removalReview(model))
        let next = try model.previewNextRequest(model.draft, hasImage: false, expectedDraftKey: model.draftKey)
        XCTAssertEqual(previous.plan.referenceDocuments.map(\.id), [f.doc(0), f.doc(1), f.doc(2)])
        XCTAssertEqual(next.plan.referenceDocuments.map(\.id), [f.doc(2)])
        XCTAssertTrue(next.plan.effectiveSystemPrompt.contains("[资料1] " + f.project.documents[2].title))
        XCTAssertFalse(next.plan.effectiveSystemPrompt.contains(f.project.documents[0].body))
        XCTAssertEqual(next.plan.messages.map(\.content), previous.plan.messages.map(\.content))
        XCTAssertEqual(next.plan.messages.map(\.role), previous.plan.messages.map(\.role))
        let review = try f.removalReview(f.model(), conversations: [f.archivedID])
        try model.applyProjectReferenceRemoval(review); try f.assertRemovalRejected(model, review)
    }

    @MainActor func testBusyReplyBlocksReferenceMutation() async throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model(pendingSend: true); let review = try f.removalReview(model)
        XCTAssertTrue(model.send("测试忙碌保护")); XCTAssertTrue(model.isSending)
        let before = model.selectedConversation?.referenceDocumentIDs
        XCTAssertThrowsError(try f.removalReview(model)); XCTAssertThrowsError(try model.applyProjectReferenceRemoval(review))
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, before)
        model.cancelSend()
        for _ in 0..<100 where model.isSending { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isSending)
    }

    @MainActor func testReviewedDraftQuoteAndRemovalPreserveEachOtherInEitherOrder() throws {
        for removeFirst in [true, false] {
            let f = try RemovalFixture.make(owner: self); let model = f.model()
            let target = LocalMessageTarget(conversationID: f.archivedID, messageID: f.records[1].messages[1].id)
            let quote = try model.makeMessageDraftQuote([target], profileID: f.profileID)
            let review = try f.removalReview(model)
            if removeFirst { try model.applyProjectReferenceRemoval(review); try model.applyMessageDraftQuote(quote, mode: .append) }
            else { try model.applyMessageDraftQuote(quote, mode: .append); try model.applyProjectReferenceRemoval(review) }
            XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, [f.doc(2)])
            XCTAssertEqual(model.draft, try MessageDraftQuote.draft(current: quote.draftText, reference: MessageDraftQuote.referenceText(quote.source), mode: .append))
            XCTAssertFalse(model.draft.contains("保留收藏备注"))
        }
    }

    @MainActor func testAdditionAfterRemovalRequiresFreshReviewAndAppendsChosenOrder() throws {
        let f = try RemovalFixture.make(owner: self); let model = f.model()
        let stale = try model.previewProjectReferenceAddition(documentIDs: [f.doc(3)], conversationIDs: [f.activeID], projectID: f.projectID, profileID: f.profileID)
        try model.applyProjectReferenceRemoval(f.removalReview(model))
        XCTAssertThrowsError(try model.applyProjectReferenceAddition(stale))
        let add = try model.previewProjectReferenceAddition(documentIDs: [f.doc(1), f.doc(0)], conversationIDs: [f.activeID], projectID: f.projectID, profileID: f.profileID)
        try model.applyProjectReferenceAddition(add)
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, [f.doc(2), f.doc(1), f.doc(0)])
    }
}

@MainActor enum RemovalFixture {
    static func make(owner: XCTestCase) throws -> AdditionFixture {
        let f = try AdditionFixture.make(owner: owner)
        var records = f.records
        records[0].referenceDocumentIDs = [f.doc(0), f.doc(1), f.doc(2)]
        records[2].referenceDocumentIDs = [f.doc(2), f.doc(0), f.doc(1)]
        records[3].title = "仅保留独立资料 · 无需改动"; records[3].referenceDocumentIDs = [f.doc(2)]
        try JSONEncoder().encode(records).write(to: f.directory.appendingPathComponent("conversations.json"))
        return AdditionFixture(defaults: f.defaults, directory: f.directory, profileID: f.profileID,
            otherProfileID: f.otherProfileID, project: f.project, otherProjectID: f.otherProjectID, records: records)
    }
}

@MainActor extension AdditionFixture {
    func removalReview(_ model: AppModel, conversations: Set<UUID>? = nil) throws -> ProjectReferenceRemovalReview {
        try model.previewProjectReferenceRemoval(documentIDs: [doc(0), doc(1)], conversationIDs: conversations ?? [activeID], projectID: projectID, profileID: profileID)
    }
    func assertRemovalRejected(_ model: AppModel, _ review: ProjectReferenceRemovalReview, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try model.makeBackup(); let files = try files(); let selected = model.selectedID; let draft = model.draft
        XCTAssertThrowsError(try model.applyProjectReferenceRemoval(review), file: file, line: line)
        let after = try model.makeBackup()
        XCTAssertEqual(after.conversations, before.conversations, file: file, line: line)
        XCTAssertEqual(after.profiles, before.profiles, file: file, line: line)
        XCTAssertEqual(after.drafts, before.drafts, file: file, line: line); XCTAssertEqual(after.images, before.images, file: file, line: line)
        XCTAssertEqual(try self.files(), files, file: file, line: line)
        XCTAssertEqual(model.selectedID, selected, file: file, line: line); XCTAssertEqual(model.draft, draft, file: file, line: line)
    }
}
