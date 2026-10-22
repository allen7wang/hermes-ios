import XCTest
@testable import Hermes

final class ProjectReferenceReplacementModelTests: XCTestCase {
    @MainActor func testPreviewIsReadOnlyAndIncludesEveryInvolvedDocumentSnapshot() throws {
        let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
        let before = try model.makeBackup(); let files = try f.files()
        let selection = model.selectedID; let draft = model.draft
        let review = try f.review(model, conversations: [f.activeID, f.archivedID, f.trashID])
        XCTAssertEqual(review.profileID, f.profileID); XCTAssertEqual(review.projectID, f.projectID)
        XCTAssertEqual(review.source, f.documents[0]); XCTAssertEqual(review.target, f.documents[1])
        XCTAssertEqual(Set(review.documents.map(\.id)), Set(f.documents.prefix(3).map(\.id)))
        XCTAssertEqual(review.rows.map(\.status), [.active, .archived, .trash])
        XCTAssertEqual(Set(review.rows.map(\.conversationID)), [f.activeID, f.archivedID, f.trashID])
        let after = try model.makeBackup()
        XCTAssertEqual(after.profiles, before.profiles); XCTAssertEqual(after.conversations, before.conversations)
        XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(try f.files(), files)
        XCTAssertEqual(model.selectedID, selection); XCTAssertEqual(model.draft, draft)
    }

    @MainActor func testApplyPersistsMixedStatesDeduplicatedOrderWithoutChangingOtherConversationData() throws {
        let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
        let before = try model.makeBackup(); let selected = model.selectedID; let draft = model.draft
        let review = try f.review(model, conversations: [f.activeID, f.archivedID, f.trashID])
        try model.applyProjectReferenceReplacement(review)
        let after = try model.makeBackup()
        let expected: [UUID: [UUID]] = [f.activeID: [f.targetID, f.extraID],
            f.archivedID: [f.extraID, f.targetID], f.trashID: [f.targetID, f.extraID]]
        for original in before.conversations {
            var wanted = original
            if let ids = expected[original.id] { wanted.referenceDocumentIDs = ids }
            XCTAssertEqual(after.conversations.first { $0.id == original.id }, wanted)
        }
        XCTAssertEqual(after.profiles, before.profiles); XCTAssertEqual(after.drafts, before.drafts)
        XCTAssertEqual(model.selectedID, selected); XCTAssertEqual(model.draft, draft)
        let reopened = f.model()
        XCTAssertEqual(try reopened.makeBackup().conversations, after.conversations)
        XCTAssertEqual(reopened.selectedID, selected); XCTAssertEqual(reopened.draft, draft)
        XCTAssertEqual(try reopened.makeBackup().version, 7)
        let decoded = try BackupArchive.decode(reopened.makeBackup().encoded())
        XCTAssertEqual(decoded.conversations, after.conversations)
        XCTAssertEqual(decoded.profiles, after.profiles)
    }

    @MainActor func testOnlyExplicitSubsetChangesAndNewUnselectedReferencesDoNotExpandReview() throws {
        let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
        let review = try f.review(model)
        try model.selectProjectDocuments([f.sourceID, f.targetID], conversationID: f.plainID, profileID: f.profileID)
        try model.selectProjectDocuments([f.extraID], conversationID: f.unselectedID, profileID: f.profileID)
        let beforeApply = try model.makeBackup()
        try model.applyProjectReferenceReplacement(review)
        let after = try model.makeBackup()
        for original in beforeApply.conversations where original.id != f.activeID {
            XCTAssertEqual(after.conversations.first { $0.id == original.id }, original)
        }
        XCTAssertEqual(after.conversations.first { $0.id == f.activeID }?.referenceDocumentIDs, [f.targetID, f.extraID])
        XCTAssertEqual(after.conversations.first { $0.id == f.plainID }?.referenceDocumentIDs, [f.sourceID, f.targetID])
    }

    @MainActor func testChangedNonSourceReferenceSlotRejectsTheEntireReview() throws {
        let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
        let review = try f.review(model, conversations: [f.activeID, f.archivedID])
        try model.selectProjectDocuments([f.sourceID, f.unrelatedID], conversationID: f.activeID, profileID: f.profileID)
        try f.assertRejectedWithoutWrites(model, review: review, changed: true)
    }

    @MainActor func testChangedTitleRejectsReviewedConversation() throws {
        let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
        let review = try f.review(model)
        model.rename(f.activeID, to: "复核后修改的标题")
        try f.assertRejectedWithoutWrites(model, review: review, changed: true)
    }

    @MainActor func testChangedArchiveOrTrashStatusRejectsReviewedConversation() throws {
        for trash in [false, true] {
            let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
            let review = try f.review(model)
            if trash { try model.deleteConversations([f.activeID]) }
            else { try model.setArchived([f.activeID], archived: true) }
            try f.assertRejectedWithoutWrites(model, review: review, changed: true)
        }
    }

    @MainActor func testMovedOrPermanentlyDeletedConversationCannotApplyStaleReview() throws {
        for removed in [false, true] {
            let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
            let review = try f.review(model)
            if removed {
                try model.deleteConversations([f.activeID])
                try model.permanentlyDeleteConversations([f.activeID])
            } else {
                try model.assignConversations([f.activeID], toProject: f.otherProjectID, profileID: f.profileID)
            }
            try f.assertRejectedWithoutWrites(model, review: review)
        }
    }

    @MainActor func testEditingSourceTargetOrAnotherSelectedDocumentInvalidatesSnapshot() throws {
        for documentIndex in 0..<3 {
            let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
            let review = try f.review(model)
            let original = f.documents[documentIndex]
            _ = try model.saveProjectDocument(id: original.id, projectID: f.projectID, title: original.title,
                body: "复核后更新的正文", profileID: f.profileID)
            try f.assertRejectedWithoutWrites(model, review: review, changed: true)
        }
    }

    @MainActor func testUnrelatedDocumentEditIsAllowedAndRemainsIntact() throws {
        let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
        let review = try f.review(model)
        _ = try model.saveProjectDocument(id: f.unrelatedID, projectID: f.projectID, title: "无关资料的新标题",
            body: "不参与本次替换的正文", profileID: f.profileID)
        let profiles = model.profiles
        try model.applyProjectReferenceReplacement(review)
        XCTAssertEqual(model.profiles, profiles)
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, [f.targetID, f.extraID])
        XCTAssertEqual(model.projects.first { $0.id == f.projectID }?.documents.first { $0.id == f.unrelatedID }?.body,
            "不参与本次替换的正文")
    }

    @MainActor func testPreviewRejectsSameDocumentEmptySelectionAndConversationWithoutSource() throws {
        let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
        let files = try f.files()
        XCTAssertThrowsError(try model.previewProjectReferenceReplacement(sourceID: f.sourceID, targetID: f.sourceID,
            conversationIDs: [f.activeID], projectID: f.projectID, profileID: f.profileID)) { error in
            guard case ProjectReferenceReplacementError.sameDocument = error else { return XCTFail("Expected same-document error") }
        }
        XCTAssertThrowsError(try f.review(model, conversations: [])) { error in
            guard case ProjectReferenceReplacementError.emptySelection = error else { return XCTFail("Expected empty-selection error") }
        }
        XCTAssertThrowsError(try f.review(model, conversations: [f.activeID, f.plainID])) { error in
            guard case ProjectReferenceReplacementError.missingReference = error else { return XCTFail("Expected missing-reference error") }
        }
        XCTAssertThrowsError(try model.previewProjectReferenceReplacement(sourceID: UUID(), targetID: f.targetID,
            conversationIDs: [f.activeID], projectID: f.projectID, profileID: f.profileID))
        XCTAssertThrowsError(try model.previewProjectReferenceReplacement(sourceID: f.sourceID, targetID: UUID(),
            conversationIDs: [f.activeID], projectID: f.projectID, profileID: f.profileID))
        XCTAssertEqual(try f.files(), files)
    }

    @MainActor func testPreviewAndApplyEnforceExactProfileAndProjectScope() throws {
        let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
        let review = try f.review(model)
        XCTAssertThrowsError(try f.review(model, conversations: [f.foreignProjectConversationID]))
        XCTAssertThrowsError(try f.review(model, conversations: [f.foreignProfileConversationID]))
        XCTAssertThrowsError(try f.review(model, conversations: [UUID()]))
        XCTAssertThrowsError(try model.previewProjectReferenceReplacement(sourceID: f.sourceID, targetID: f.targetID,
            conversationIDs: [f.activeID], projectID: f.otherProjectID, profileID: f.profileID))
        model.selectProfile(f.otherProfileID)
        XCTAssertThrowsError(try f.review(model))
        try f.assertRejectedWithoutWrites(model, review: review)
        model.selectProfile(f.profileID)
        try model.applyProjectReferenceReplacement(review)
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, [f.targetID, f.extraID])
    }

    @MainActor func testRecoveryBlocksOldReviewAndPreservesMalformedDraftFile() throws {
        let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
        let review = try f.review(model)
        let corrupt = Data("{not-readable".utf8)
        try corrupt.write(to: f.directory.appendingPathComponent("drafts.json"))
        let reopened = f.model(); XCTAssertTrue(reopened.needsRecovery)
        let conversations = try Data(contentsOf: f.directory.appendingPathComponent("conversations.json"))
        XCTAssertThrowsError(try f.review(reopened))
        XCTAssertThrowsError(try reopened.applyProjectReferenceReplacement(review))
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("drafts.json")), corrupt)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("conversations.json")), conversations)
    }

    @MainActor func testOneOverBudgetRowRejectsWholeBatchBeforeWritingAnyConversation() throws {
        let f = try ReplacementModelFixture.make(owner: self, overBudget: true); let model = f.model()
        XCTAssertFalse(model.needsRecovery)
        _ = try f.review(model) // The first selected conversation is individually safe.
        let before = try model.makeBackup(); let files = try f.files()
        XCTAssertThrowsError(try f.review(model, conversations: [f.activeID, f.archivedID]))
        let after = try model.makeBackup()
        XCTAssertEqual(after.conversations, before.conversations); XCTAssertEqual(after.profiles, before.profiles)
        XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(try f.files(), files)
    }

    @MainActor func testConversationWriteFailureDoesNotPublishPartialState() throws {
        let f = try ReplacementModelFixture.make(owner: self); let model = f.model()
        let review = try f.review(model, conversations: [f.activeID, f.archivedID, f.trashID])
        let before = try model.makeBackup(); let selected = model.selectedID; let draft = model.draft
        let url = f.directory.appendingPathComponent("conversations.json")
        let originalData = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.applyProjectReferenceReplacement(review))
        let after = try model.makeBackup()
        XCTAssertEqual(after.conversations, before.conversations); XCTAssertEqual(after.profiles, before.profiles)
        XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(model.selectedID, selected); XCTAssertEqual(model.draft, draft)
        XCTAssertFalse(model.needsRecovery)
        try FileManager.default.removeItem(at: url)
        try originalData.write(to: url, options: .atomic)
        XCTAssertEqual(try f.model().makeBackup().conversations, before.conversations)
    }
}

@MainActor private struct ReplacementModelFixture {
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
    let unselectedID: UUID
    let plainID: UUID
    let foreignProjectConversationID: UUID
    let foreignProfileConversationID: UUID
    var sourceID: UUID { documents[0].id }
    var targetID: UUID { documents[1].id }
    var extraID: UUID { documents[2].id }
    var unrelatedID: UUID { documents[3].id }

    static func make(owner: XCTestCase, overBudget: Bool = false) throws -> Self {
        let suite = "HermesReferenceReplacementModel.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_792_600_000)
        let documents = (0..<4).map { index in
            ProjectDocument(title: ["旧版资料", "新版资料", "保留的参考", "其他资料"][index],
                body: overBudget ? String(repeating: "字", count: index == 0 ? 10_000 : 20_000) : "完整正文\(index)",
                createdAt: date, updatedAt: date)
        }
        let project = LocalProject(name: "引用替换项目", summary: "本地整理", instructions: "保留原始消息", createdAt: date,
            updatedAt: date, knowledgeDocuments: documents)
        let other = LocalProject(name: "其他项目", summary: "", instructions: "", createdAt: date,
            updatedAt: date.addingTimeInterval(-1), knowledgeDocuments: documents)
        let profile = ConnectionProfile(name: "当前连接", serverURL: "https://reference-replacement.hermes.test", model: "hermes-agent",
            localProjects: [project, other])
        let foreign = ConnectionProfile(name: "另一连接", serverURL: "https://foreign-reference.hermes.test", model: "hermes-agent", localProjects: [project])
        let source = documents[0].id; let target = documents[1].id; let extra = documents[2].id
        func conversation(_ title: String, refs: [UUID], archived: Bool = false, trashed: Bool = false,
                          profileID: UUID? = nil, projectID: UUID? = nil) -> Conversation {
            Conversation(title: title, messages: [
                .init(role: .user, content: "保留的问题与旧 [资料1]", createdAt: date),
                .init(role: .assistant, content: "保留的回答", createdAt: date,
                    bookmark: .init(createdAt: date, note: "原收藏备注"))], updatedAt: date,
                profileID: profileID ?? profile.id, pinned: true,
                workspace: .init(tags: ["保留标签"], archived: archived,
                    configuration: .init(model: "自选模型", provider: "", systemPrompt: "原对话指令", contextTurns: 2),
                    trashedAt: trashed ? date : nil),
                projectID: projectID ?? project.id, referenceDocumentIDs: refs)
        }
        let active = conversation("进行中", refs: overBudget ? [source] : [source, extra])
        let archived = conversation("归档", refs: overBudget ? [source, extra, documents[3].id] : [extra, target, source], archived: true)
        let trash = conversation("回收站", refs: [source, target, extra], archived: true, trashed: true)
        let unselected = conversation("未选择", refs: [extra, source])
        let plain = conversation("未引用旧资料", refs: [extra])
        let foreignProject = conversation("其他项目中的同名资料", refs: [source], projectID: other.id)
        let foreignProfile = conversation("另一连接中的同名资料", refs: [source], profileID: foreign.id)
        let library = ConnectionLibrary(profiles: [profile, foreign], activeID: profile.id,
            selectedConversations: [profile.id.uuidString: active.id.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"))
        try JSONEncoder().encode([active, archived, trash, unselected, plain, foreignProject, foreignProfile])
            .write(to: directory.appendingPathComponent("conversations.json"))
        let drafts = [DraftStore.localKey(profileID: profile.id, conversationID: active.id): "输入框草稿",
            DraftStore.localKey(profileID: profile.id, conversationID: archived.id): "归档对话草稿",
            DraftStore.localKey(profileID: profile.id, conversationID: trash.id): "回收站草稿",
            DraftStore.localKey(profileID: profile.id, conversationID: nil): "新对话草稿"]
        try JSONEncoder().encode(drafts).write(to: directory.appendingPathComponent("drafts.json"))
        owner.addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return Self(defaults: defaults, directory: directory, profileID: profile.id, otherProfileID: foreign.id,
            projectID: project.id, otherProjectID: other.id, documents: documents,
            activeID: active.id, archivedID: archived.id, trashID: trash.id, unselectedID: unselected.id, plainID: plain.id,
            foreignProjectConversationID: foreignProject.id, foreignProfileConversationID: foreignProfile.id)
    }

    func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplacementModelNetworkGuard.self]
        return AppModel(defaults: defaults, directory: directory, credentials: MemoryCredentials(), sessionConfiguration: configuration)
    }

    func review(_ model: AppModel, conversations: Set<UUID>? = nil) throws -> ProjectReferenceReplacementReview {
        try model.previewProjectReferenceReplacement(sourceID: sourceID, targetID: targetID,
            conversationIDs: conversations ?? [activeID], projectID: projectID, profileID: profileID)
    }

    func files() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["connections.json", "conversations.json", "drafts.json"].map {
            ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
        })
    }

    func assertRejectedWithoutWrites(_ model: AppModel, review: ProjectReferenceReplacementReview,
                                    changed: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try model.makeBackup(); let files = try files()
        let selected = model.selectedID; let draft = model.draft
        XCTAssertThrowsError(try model.applyProjectReferenceReplacement(review), file: file, line: line) { error in
            if changed {
                guard case ProjectReferenceReplacementError.changed = error else {
                    return XCTFail("Expected changed-review error, received \(error)", file: file, line: line)
                }
            }
        }
        let after = try model.makeBackup()
        XCTAssertEqual(after.conversations, before.conversations, file: file, line: line)
        XCTAssertEqual(after.profiles, before.profiles, file: file, line: line)
        XCTAssertEqual(after.drafts, before.drafts, file: file, line: line)
        XCTAssertEqual(try self.files(), files, file: file, line: line)
        XCTAssertEqual(model.selectedID, selected, file: file, line: line); XCTAssertEqual(model.draft, draft, file: file, line: line)
    }
}

private final class ReplacementModelNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Reference replacement must not send a network request")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
