import XCTest
import UIKit
@testable import Hermes

final class ProjectDocumentTests: XCTestCase {
    override func tearDown() {
        DocumentProtocol.handler = nil
        DocumentProtocol.requests = 0
        super.tearDown()
    }

    func testLegacyProjectAndConversationDecodeWithoutKnowledgeFields() throws {
        let project = try JSONDecoder().decode(LocalProject.self, from: Data(#"{"id":"30000000-0000-0000-0000-000000000001","name":"旧项目","summary":"","instructions":"","createdAt":0,"updatedAt":0}"#.utf8))
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(#"{"id":"30000000-0000-0000-0000-000000000002","title":"旧对话","messages":[],"updatedAt":0}"#.utf8))
        XCTAssertTrue(project.documents.isEmpty)
        XCTAssertTrue((conversation.referenceDocumentIDs ?? []).isEmpty)
    }

    func testDocumentValidationNormalizesEdgesAndPreservesMarkdownStructure() throws {
        let document = try ProjectDocument(title: "  发布约定  ", body: "\n# 目标\n\n- 第一项\n- 第二项\n ").validated()
        XCTAssertEqual(document.title, "发布约定")
        XCTAssertEqual(document.body, "# 目标\n\n- 第一项\n- 第二项")
        XCTAssertEqual(try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(document)), document)
    }

    func testDocumentValidationRejectsBlankOversizeAndInvalidDates() {
        let invalid = [ProjectDocument(title: " ", body: "正文"), ProjectDocument(title: "多\n行", body: "正文"),
            ProjectDocument(title: String(repeating: "字", count: 81), body: "正文"), ProjectDocument(title: "资料", body: " \n"),
            ProjectDocument(title: "资料", body: String(repeating: "字", count: 20_001)),
            ProjectDocument(title: "资料", body: "正文", createdAt: Date(timeIntervalSince1970: .infinity))]
        for document in invalid { XCTAssertThrowsError(try document.validated()) }
        XCTAssertNoThrow(try ProjectDocument(title: String(repeating: "字", count: 80), body: String(repeating: "字", count: 20_000)).validated())
    }

    func testDocumentCollectionRejectsDuplicatesCountAndTotalCharacterOverflow() throws {
        let one = ProjectDocument(title: "资料", body: "正文")
        XCTAssertThrowsError(try ProjectDocument.validateCollection([one, one]))
        XCTAssertThrowsError(try ProjectDocument.validateCollection((0...20).map { ProjectDocument(title: "资料\($0)", body: "正文") }))
        let full = (0..<10).map { ProjectDocument(title: "资料\($0)", body: String(repeating: "字", count: 20_000)) }
        XCTAssertNoThrow(try ProjectDocument.validateCollection(full))
        XCTAssertThrowsError(try ProjectDocument.validateCollection(full + [one]))
    }

    func testSelectionPreservesExplicitOrderAndEmptySelectionNeedsNoProject() throws {
        let first = ProjectDocument(title: "第一篇", body: "甲")
        let second = ProjectDocument(title: "第二篇", body: "乙")
        let project = project(documents: [first, second])
        XCTAssertEqual(try ProjectDocument.selected(ids: [second.id, first.id], from: project), [second, first])
        XCTAssertTrue(try ProjectDocument.selected(ids: [], from: nil).isEmpty)
    }

    func testSelectionRejectsDuplicateMissingForeignAndTooManyReferences() throws {
        let documents = (0..<6).map { ProjectDocument(title: "资料\($0)", body: "正文") }
        let project = project(documents: documents)
        XCTAssertThrowsError(try ProjectDocument.selected(ids: [documents[0].id, documents[0].id], from: project))
        XCTAssertThrowsError(try ProjectDocument.selected(ids: [UUID()], from: project))
        XCTAssertThrowsError(try ProjectDocument.selected(ids: [documents[0].id], from: nil))
        XCTAssertThrowsError(try ProjectDocument.selected(ids: documents.map(\.id), from: project))
    }

    func testSelectedCharacterBudgetAcceptsBoundaryAndRejectsOverflow() throws {
        let docs = [20_000, 20_000, 10_000, 1].map { ProjectDocument(title: "资料", body: String(repeating: "字", count: $0)) }
        XCTAssertEqual(try ProjectDocument.selected(ids: Array(docs.prefix(3)).map(\.id), from: project(documents: docs)).count, 3)
        XCTAssertThrowsError(try ProjectDocument.selected(ids: docs.map(\.id), from: project(documents: docs)))
    }

    func testTextImportSupportsUTF8BOMMarkdownAndPlainText() throws {
        let body = "# 发布清单\n\n检查资料和引用。"
        let markdown = try ProjectDocument.importText(data: Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8), filename: "发布清单.MD")
        XCTAssertEqual(markdown.body, body)
        XCTAssertTrue(markdown.title.contains("发布清单"))
        XCTAssertEqual(try ProjectDocument.importText(data: Data("纯文本资料".utf8), filename: "资料.txt").body, "纯文本资料")
    }

    func testTextImportRejectsUnsupportedEncodingTypeAndSizeBeforeSaving() {
        XCTAssertThrowsError(try ProjectDocument.importText(data: Data([0xFF, 0xFE, 0x41, 0]), filename: "资料.txt"))
        XCTAssertThrowsError(try ProjectDocument.importText(data: Data("正文".utf8), filename: "资料.pdf"))
        XCTAssertThrowsError(try ProjectDocument.importText(data: Data(repeating: 0x41, count: 256 * 1024 + 1), filename: "资料.md"))
        XCTAssertThrowsError(try ProjectDocument.importText(data: Data(String(repeating: "字", count: 20_001).utf8), filename: "资料.txt"))
        XCTAssertThrowsError(try ProjectDocument.importText(data: Data(" \n".utf8), filename: "空白.md"))
    }

    @MainActor func testDocumentCRUDPersistsAndProjectAndProfileEditsKeepKnowledge() throws {
        let f = try fixture(); let model = f.model(); let projectID = try addProject(model)
        let id = try model.saveProjectDocument(id: nil, projectID: projectID, title: "  原资料  ", body: "原正文", profileID: model.activeProfileID)
        let created = try document(id, in: model)
        _ = try model.saveProjectDocument(id: id, projectID: projectID, title: "更新资料", body: "更新正文", profileID: model.activeProfileID)
        XCTAssertEqual(try document(id, in: model).createdAt, created.createdAt)
        _ = try model.saveProject(id: projectID, name: "项目重命名", summary: "新简介", instructions: "新指令", profileID: model.activeProfileID)
        _ = try model.saveProfile(id: model.activeProfileID, name: "连接重命名", connection: model.settings)
        XCTAssertEqual(try document(id, in: f.model()).body, "更新正文")
        XCTAssertEqual(DocumentProtocol.requests, 0)
    }

    @MainActor func testDocumentSaveFailureKeepsPublishedKnowledgeAndReferences() throws {
        let f = try fixture(); let model = f.model(); let projectID = try addProject(model)
        let id = try addDocument(model, projectID: projectID)
        let before = model.projects
        let url = f.directory.appendingPathComponent("connections.json")
        try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.saveProjectDocument(id: id, projectID: projectID, title: "不应保存", body: "不应发布", profileID: model.activeProfileID))
        XCTAssertEqual(model.projects, before)
        XCTAssertFalse(model.needsRecovery)
    }

    @MainActor func testDocumentMutationsRejectStaleProfilesAndForeignProjects() throws {
        let model = try fixture().model(); let profileID = model.activeProfileID
        let projectID = try addProject(model); let id = try addDocument(model, projectID: projectID)
        let other = try model.saveProfile(id: nil, name: "另一连接", connection: .init(serverURL: "https://other.document.test", model: "hermes-agent", apiKey: "fixture-only"))
        XCTAssertThrowsError(try model.saveProjectDocument(id: id, projectID: projectID, title: "越界", body: "越界", profileID: profileID))
        XCTAssertThrowsError(try model.deleteProjectDocument(id, projectID: projectID, profileID: other))
        XCTAssertTrue(model.projects.isEmpty)
        model.selectProfile(profileID); XCTAssertEqual(try document(id, in: model).body, "示例正文")
    }

    @MainActor func testConversationReferenceSelectionsPersistIndependentlyInOrder() throws {
        let f = try fixture(); let model = f.model(); let projectID = try addProject(model)
        let first = try addDocument(model, projectID: projectID, title: "第一篇")
        let second = try addDocument(model, projectID: projectID, title: "第二篇")
        let records = model.conversations
        try model.assignConversations(Set(records.map(\.id)), toProject: projectID, profileID: model.activeProfileID)
        try model.selectProjectDocuments([second, first], conversationID: records[0].id, profileID: model.activeProfileID)
        try model.selectProjectDocuments([first], conversationID: records[1].id, profileID: model.activeProfileID)
        model.select(records[0].id); XCTAssertEqual(model.currentReferenceDocuments.map(\.id), [second, first])
        let reopened = f.model(); reopened.select(records[1].id)
        XCTAssertEqual(reopened.currentReferenceDocuments.map(\.id), [first])
        XCTAssertEqual(DocumentProtocol.requests, 0)
    }

    @MainActor func testInvalidReferenceSelectionLeavesConversationUnchangedAndRejectsTrashOrNoProject() throws {
        let model = try fixture().model(); let id = try XCTUnwrap(model.selectedID)
        XCTAssertThrowsError(try model.selectProjectDocuments([UUID()], conversationID: id, profileID: model.activeProfileID))
        let projectID = try addProject(model); let documentID = try addDocument(model, projectID: projectID)
        try model.assignConversations([id], toProject: projectID, profileID: model.activeProfileID)
        try model.selectProjectDocuments([documentID], conversationID: id, profileID: model.activeProfileID)
        let before = model.selectedConversation
        XCTAssertThrowsError(try model.selectProjectDocuments([UUID()], conversationID: id, profileID: model.activeProfileID))
        XCTAssertEqual(model.selectedConversation, before)
        try model.setArchived([id], archived: true)
        XCTAssertNoThrow(try model.selectProjectDocuments([], conversationID: id, profileID: model.activeProfileID))
        try model.deleteConversations([id])
        XCTAssertThrowsError(try model.selectProjectDocuments([], conversationID: id, profileID: model.activeProfileID))
    }

    @MainActor func testMovingProjectClearsReferencesWhileSavingSameProjectPreservesThem() throws {
        let model = try fixture().model(); let projectID = try addProject(model); let other = try addProject(model, name: "另一项目")
        let documentID = try addDocument(model, projectID: projectID); let id = try XCTUnwrap(model.selectedID)
        try model.assignConversations([id], toProject: projectID, profileID: model.activeProfileID)
        try model.selectProjectDocuments([documentID], conversationID: id, profileID: model.activeProfileID)
        try model.saveConversationSettings(title: "同一项目", tags: "", configuration: .init(), expectedDraftKey: model.draftKey, profileID: model.activeProfileID, project: .project(projectID))
        XCTAssertEqual(model.currentReferenceDocuments.map(\.id), [documentID])
        try model.saveConversationSettings(title: "换项目", tags: "", configuration: .init(), expectedDraftKey: model.draftKey, profileID: model.activeProfileID, project: .project(other))
        XCTAssertTrue(model.currentReferenceDocuments.isEmpty)
        try model.assignConversations([id], toProject: nil, profileID: model.activeProfileID)
        XCTAssertTrue((model.selectedConversation?.referenceDocumentIDs ?? []).isEmpty)
    }

    @MainActor func testBranchInheritsReferenceSelectionWithoutCopyingDocumentRecords() throws {
        let model = try fixture().model(); let projectID = try addProject(model); let docID = try addDocument(model, projectID: projectID)
        let source = try XCTUnwrap(model.selectedConversation)
        try model.assignConversations([source.id], toProject: projectID, profileID: model.activeProfileID)
        try model.selectProjectDocuments([docID], conversationID: source.id, profileID: model.activeProfileID)
        XCTAssertTrue(model.branchConversation(at: source.messages.last!.id))
        XCTAssertNotEqual(model.selectedID, source.id)
        XCTAssertEqual(model.currentReferenceDocuments.map(\.id), [docID])
        XCTAssertEqual(model.projects.first?.documents.count, 1)
    }

    @MainActor func testDeletingDocumentClearsActiveArchivedAndTrashedReferencesWithoutDeletingContent() throws {
        let f = try fixture(image: true); let model = f.model(); let projectID = try addProject(model)
        let removed = try addDocument(model, projectID: projectID); let kept = try addDocument(model, projectID: projectID, title: "保留资料")
        let active = try XCTUnwrap(model.selectedID); model.draft = "保留草稿"
        let second = try XCTUnwrap(model.conversations.first { $0.id != active }?.id)
        try model.assignConversations([active, second], toProject: projectID, profileID: model.activeProfileID)
        try model.selectProjectDocuments([removed, kept], conversationID: active, profileID: model.activeProfileID)
        try model.selectProjectDocuments([removed], conversationID: second, profileID: model.activeProfileID)
        try model.setArchived([active], archived: true); try model.deleteConversations([second])
        let before = try model.makeBackup()
        try model.deleteProjectDocument(removed, projectID: projectID, profileID: model.activeProfileID)
        let after = try model.makeBackup()
        XCTAssertEqual(after.images, before.images); XCTAssertEqual(after.drafts, before.drafts)
        XCTAssertEqual(after.conversations.map(\.messages), before.conversations.map(\.messages))
        XCTAssertEqual(after.conversations.first { $0.id == active }?.referenceDocumentIDs ?? [], [kept])
        XCTAssertTrue(after.conversations.filter { $0.id == second }.allSatisfy { ($0.referenceDocumentIDs ?? []).isEmpty })
        XCTAssertEqual(model.draft, "保留草稿"); XCTAssertFalse(f.model().needsRecovery)
    }

    @MainActor func testDeletingDocumentInterruptedTransactionRecoversConsistentSelections() throws {
        let f = try fixture(); let model = f.model(); let projectID = try addProject(model); let docID = try addDocument(model, projectID: projectID)
        let id = try XCTUnwrap(model.selectedID)
        try model.assignConversations([id], toProject: projectID, profileID: model.activeProfileID)
        try model.selectProjectDocuments([docID], conversationID: id, profileID: model.activeProfileID)
        let draftURL = f.directory.appendingPathComponent("drafts.json")
        if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
        try FileManager.default.createDirectory(at: draftURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.deleteProjectDocument(docID, projectID: projectID, profileID: model.activeProfileID))
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs ?? [], [docID]); XCTAssertTrue(model.needsRecovery)
        XCTAssertNotNil(model.projects.first?.documents.first { $0.id == docID })
        try FileManager.default.removeItem(at: draftURL)
        let reopened = f.model(); XCTAssertFalse(reopened.needsRecovery)
        XCTAssertTrue(reopened.projects.first!.documents.isEmpty); XCTAssertTrue(reopened.currentReferenceDocuments.isEmpty)
    }

    @MainActor func testEditingSelectedDocumentCannotInvalidateAnyTrashedConversationBudget() throws {
        let model = try fixture().model(); let projectID = try addProject(model)
        let docs = try [20_000, 20_000, 10_000].enumerated().map { index, count in
            try addDocument(model, projectID: projectID, title: "资料\(index)", body: String(repeating: "字", count: count))
        }
        let id = try XCTUnwrap(model.selectedID)
        try model.assignConversations([id], toProject: projectID, profileID: model.activeProfileID)
        try model.selectProjectDocuments(docs, conversationID: id, profileID: model.activeProfileID)
        try model.deleteConversations([id])
        XCTAssertThrowsError(try model.saveProjectDocument(id: docs[2], projectID: projectID, title: "超限编辑", body: String(repeating: "字", count: 10_001), profileID: model.activeProfileID))
        XCTAssertEqual(try document(docs[2], in: model).body.count, 10_000)
    }

    @MainActor func testDissolvingProjectClearsAllReferenceIDsAndKeepsMessages() throws {
        let model = try fixture().model(); let projectID = try addProject(model); let docID = try addDocument(model, projectID: projectID)
        let ids = Set(model.conversations.map(\.id))
        try model.assignConversations(ids, toProject: projectID, profileID: model.activeProfileID)
        for id in ids { try model.selectProjectDocuments([docID], conversationID: id, profileID: model.activeProfileID) }
        let before = model.conversations.map(\.messages)
        try model.deleteProject(projectID, profileID: model.activeProfileID)
        XCTAssertTrue(model.conversations.allSatisfy { $0.projectID == nil && ($0.referenceDocumentIDs ?? []).isEmpty })
        XCTAssertEqual(model.conversations.map(\.messages), before)
    }

    func testPreparedContextIncludesOnlyExplicitReferenceBodiesInSelectedOrder() throws {
        let first = ProjectDocument(title: "第一篇", body: "甲正文完整内容")
        let second = ProjectDocument(title: "第二篇", body: "乙正文完整内容")
        let hidden = ProjectDocument(title: "未选资料", body: "不应发送的秘密资料")
        let project = project(documents: [first, second, hidden])
        let plan = try PreparedChatContext(messages: [ChatMessage(role: .user, content: "问题")], configuration: .init(systemPrompt: "对话指令"), project: project, referenceDocumentIDs: [second.id, first.id])
        XCTAssertEqual(plan.referenceDocuments, [second, first])
        let prompt = plan.effectiveSystemPrompt
        XCTAssertTrue(prompt.contains(second.body)); XCTAssertTrue(prompt.contains(first.body)); XCTAssertFalse(prompt.contains(hidden.body))
        XCTAssertFalse(prompt.contains(project.summary))
        XCTAssertLessThan(try XCTUnwrap(prompt.range(of: second.body)?.lowerBound), try XCTUnwrap(prompt.range(of: first.body)?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(prompt.range(of: "对话指令")?.lowerBound), try XCTUnwrap(prompt.range(of: second.body)?.lowerBound))
    }

    func testKnowledgeIsNotAutomaticallySentAndInvalidSelectionFailsBeforeRequest() throws {
        let doc = ProjectDocument(title: "资料", body: "尚未授权发送的正文")
        let project = project(documents: [doc])
        let plan = try PreparedChatContext(messages: [], configuration: .init(), project: project)
        XCTAssertTrue(plan.referenceDocuments.isEmpty); XCTAssertFalse(plan.effectiveSystemPrompt.contains(doc.body))
        XCTAssertThrowsError(try PreparedChatContext(messages: [], configuration: .init(), project: project, referenceDocumentIDs: [UUID()]))
        XCTAssertThrowsError(try PreparedChatContext(messages: [], configuration: .init(), referenceDocumentIDs: [doc.id]))
    }

    @MainActor func testActualWireMatchesPreviewAndUsesLatestSelectedDocumentWithoutUnselectedData() async throws {
        let model = try fixture().model(); let projectID = try addProject(model); let conversationID = try XCTUnwrap(model.selectedID)
        let doc = try addDocument(model, projectID: projectID, body: "原版正文")
        _ = try addDocument(model, projectID: projectID, title: "未选资料", body: "未选资料绝不发送")
        try model.assignConversations([conversationID], toProject: projectID, profileID: model.activeProfileID)
        try model.selectProjectDocuments([doc], conversationID: conversationID, profileID: model.activeProfileID)
        _ = try model.saveProjectDocument(id: doc, projectID: projectID, title: "选中资料", body: "更新后的资料全文", profileID: model.activeProfileID)
        model.draft = "请结合选中资料回答。"
        let preview = try model.previewNextRequest(model.draft, hasImage: false, expectedDraftKey: model.draftKey)
        let received = expectation(description: "knowledge wire")
        DocumentProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            XCTAssertEqual(messages.first?["content"] as? String, preview.plan.effectiveSystemPrompt)
            let wire = String(decoding: request.body, as: UTF8.self)
            XCTAssertTrue(wire.contains("更新后的资料全文")); XCTAssertFalse(wire.contains("未选资料绝不发送")); XCTAssertFalse(wire.contains("本机简介不发送"))
            request.respond(); received.fulfill()
        }
        XCTAssertTrue(model.send(model.draft)); await fulfillment(of: [received], timeout: 3)
        for _ in 0..<150 where model.isSending { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSending)
    }

    @MainActor func testVersionSevenForeignRoundTripMapsDocumentsAndRepeatKeepsLocalEditsAndSelection() throws {
        let source = try fixture(); let sourceModel = source.model(); let projectID = try addProject(sourceModel)
        let first = try addDocument(sourceModel, projectID: projectID, title: "第一篇")
        let second = try addDocument(sourceModel, projectID: projectID, title: "第二篇")
        let sourceConversation = try XCTUnwrap(sourceModel.selectedID)
        try sourceModel.assignConversations([sourceConversation], toProject: projectID, profileID: sourceModel.activeProfileID)
        try sourceModel.selectProjectDocuments([second, first], conversationID: sourceConversation, profileID: sourceModel.activeProfileID)
        let archive = try BackupArchive.decode(sourceModel.makeBackup().encoded()); XCTAssertEqual(archive.version, 7)
        let destination = try fixture(empty: true); let model = destination.model()
        XCTAssertEqual(try model.importBackup(archive).documentsAdded, 2)
        let profile = try XCTUnwrap(model.profiles.first { !$0.projects.isEmpty }); model.selectProfile(profile.id)
        let importedProject = try XCTUnwrap(model.projects.first)
        let importedSecond = try XCTUnwrap(importedProject.documents.first { $0.title == "第二篇" })
        XCTAssertNotEqual(importedSecond.id, second); XCTAssertEqual(model.currentReferenceDocuments.map(\.title), ["第二篇", "第一篇"])
        _ = try model.saveProjectDocument(id: importedSecond.id, projectID: importedProject.id, title: "本机编辑", body: "本机正文", profileID: profile.id)
        try model.selectProjectDocuments([importedSecond.id], conversationID: try XCTUnwrap(model.selectedID), profileID: profile.id)
        let before = model.conversations
        XCTAssertEqual(try model.importBackup(archive).documentsAdded, 0)
        XCTAssertEqual(model.conversations, before); XCTAssertEqual(model.currentReferenceDocuments.first?.body, "本机正文")
    }

    func testVersionSevenBackupRejectsDowngradeAndUnresolvedOrDuplicateReferences() throws {
        let doc = ProjectDocument(title: "资料", body: "正文"); let project = project(documents: [doc])
        let profile = ConnectionProfile(name: "连接", serverURL: "", model: "hermes-agent", localProjects: [project])
        var record = Conversation(title: "对话", messages: [], updatedAt: Date(), profileID: profile.id, projectID: project.id)
        record.referenceDocumentIDs = [doc.id]
        var archive = BackupArchive(version: 7, installationID: UUID(), createdAt: Date(), profiles: [profile], conversations: [record], drafts: [:], images: [:])
        XCTAssertNoThrow(try archive.validate())
        archive.version = 6; XCTAssertThrowsError(try archive.validate()); archive.version = 7
        archive.conversations[0].referenceDocumentIDs = [UUID()]; XCTAssertThrowsError(try archive.validate())
        archive.conversations[0].referenceDocumentIDs = [doc.id, doc.id]; XCTAssertThrowsError(try archive.validate())
        archive.conversations[0].referenceDocumentIDs = [doc.id]; archive.conversations[0].projectID = nil
        XCTAssertThrowsError(try archive.validate())
    }

    func testIdenticalDocumentIDsInDifferentProjectsAreRemappedIndependently() throws {
        let doc = ProjectDocument(title: "同ID资料", body: "正文")
        let firstProject = project(documents: [doc]); let secondProject = project(documents: [doc])
        let profile = ConnectionProfile(name: "来源", serverURL: "", model: "hermes-agent", localProjects: [firstProject, secondProject])
        let records = [firstProject, secondProject].map { project -> Conversation in
            var record = Conversation(title: project.name, messages: [], updatedAt: Date(), profileID: profile.id, projectID: project.id)
            record.referenceDocumentIDs = [doc.id]; return record
        }
        let archive = BackupArchive(version: 7, installationID: UUID(), createdAt: Date(), profiles: [profile], conversations: records, drafts: [:], images: [:])
        let empty = ConnectionProfile(name: "空", serverURL: "", model: "hermes-agent")
        let merge = try BackupMerge.prepare(archive, installationID: UUID(), library: .init(profiles: [empty], activeID: empty.id), conversations: [], drafts: [:])
        XCTAssertEqual(merge.report.documentsAdded, 2)
        let projects = try XCTUnwrap(merge.state.library.profiles.first { !$0.projects.isEmpty }?.projects)
        XCTAssertNotEqual(projects[0].documents[0].id, projects[1].documents[0].id)
        for record in merge.state.conversations {
            XCTAssertEqual(record.referenceDocumentIDs, projects.first { $0.id == record.projectID }?.documents.map(\.id))
        }
    }

    @MainActor func testVersionSevenJournalRecoversDocumentsAndReferencesAfterInterruptedImport() throws {
        let sourceModel = try fixture().model(); let projectID = try addProject(sourceModel); let docID = try addDocument(sourceModel, projectID: projectID)
        let id = try XCTUnwrap(sourceModel.selectedID)
        try sourceModel.assignConversations([id], toProject: projectID, profileID: sourceModel.activeProfileID)
        try sourceModel.selectProjectDocuments([docID], conversationID: id, profileID: sourceModel.activeProfileID)
        let archive = try sourceModel.makeBackup()
        let f = try fixture(empty: true); let model = f.model(); let draftURL = f.directory.appendingPathComponent("drafts.json")
        if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
        try FileManager.default.createDirectory(at: draftURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.importBackup(archive)); XCTAssertTrue(model.needsRecovery)
        try FileManager.default.removeItem(at: draftURL)
        let reopened = f.model(); XCTAssertFalse(reopened.needsRecovery)
        reopened.selectProfile(try XCTUnwrap(reopened.profiles.first { !$0.projects.isEmpty }?.id))
        XCTAssertEqual(reopened.currentReferenceDocuments.map(\.body), ["示例正文"])
        XCTAssertEqual(try reopened.makeBackup().version, 7)
    }

    @MainActor func testCorruptReferenceTriggersRecoveryWithoutOverwritingOriginalConversationFile() throws {
        let f = try fixture(); let model = f.model(); let projectID = try addProject(model)
        let id = try XCTUnwrap(model.selectedID); try model.assignConversations([id], toProject: projectID, profileID: model.activeProfileID)
        let url = f.directory.appendingPathComponent("conversations.json")
        var records = try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: url))
        records[0].referenceDocumentIDs = [UUID()]
        let corrupt = try JSONEncoder().encode(records); try corrupt.write(to: url)
        let reopened = f.model(); XCTAssertTrue(reopened.needsRecovery)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertThrowsError(try reopened.saveProjectDocument(id: nil, projectID: projectID, title: "不能写入", body: "正文", profileID: reopened.activeProfileID))
    }

    @MainActor func testDocumentAndReferenceMutationsAreBlockedDuringGeneration() async throws {
        let model = try fixture().model(); let projectID = try addProject(model); let doc = try addDocument(model, projectID: projectID)
        let id = try XCTUnwrap(model.selectedID); try model.assignConversations([id], toProject: projectID, profileID: model.activeProfileID)
        let received = expectation(description: "pending document request"); var pending: DocumentProtocol?
        DocumentProtocol.handler = { pending = $0; received.fulfill() }
        XCTAssertTrue(model.send("等待回复")); await fulfillment(of: [received], timeout: 3)
        XCTAssertThrowsError(try model.saveProjectDocument(id: doc, projectID: projectID, title: "不应写入", body: "正文", profileID: model.activeProfileID))
        XCTAssertThrowsError(try model.deleteProjectDocument(doc, projectID: projectID, profileID: model.activeProfileID))
        XCTAssertThrowsError(try model.selectProjectDocuments([doc], conversationID: id, profileID: model.activeProfileID))
        pending?.respond()
        for _ in 0..<150 where model.isSending { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSending)
    }

    private func project(documents: [ProjectDocument]) -> LocalProject {
        var project = LocalProject(name: "示例项目", summary: "本机简介不发送", instructions: "项目指令")
        project.documents = documents; return project
    }

    @MainActor private func addProject(_ model: AppModel, name: String = "示例项目") throws -> UUID {
        try model.saveProject(id: nil, name: name, summary: "本机简介不发送", instructions: "项目指令", profileID: model.activeProfileID)
    }

    @MainActor private func addDocument(_ model: AppModel, projectID: UUID, title: String = "示例资料", body: String = "示例正文") throws -> UUID {
        try model.saveProjectDocument(id: nil, projectID: projectID, title: title, body: body, profileID: model.activeProfileID)
    }

    @MainActor private func document(_ id: UUID, in model: AppModel) throws -> ProjectDocument {
        try XCTUnwrap(model.projects.flatMap(\.documents).first { $0.id == id })
    }

    @MainActor private func fixture(image: Bool = false, empty: Bool = false) throws -> DocumentFixture {
        let suite = "HermesDocumentTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("https://documents.hermes.test/v1", forKey: "serverURL"); defaults.set("hermes-agent", forKey: "model")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var imageID: UUID?
        if image {
            let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }.jpegData(compressionQuality: 0.8))
            imageID = try ImageAttachmentStore.save(data, directory: directory.appendingPathComponent("Attachments"))
        }
        let records = [Conversation(title: "原对话", messages: [ChatMessage(role: .user, content: "原问题", imageID: imageID), ChatMessage(role: .assistant, content: "原答案")], updatedAt: Date()),
            Conversation(title: "另一段对话", messages: [], updatedAt: Date(timeIntervalSince1970: 1))]
        try JSONEncoder().encode(empty ? [] : records).write(to: directory.appendingPathComponent("conversations.json"))
        let keys = MemoryCredentials(); keys.values["api-server-key"] = "document-fixture-only"
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return DocumentFixture(defaults: defaults, directory: directory, keys: keys)
    }
}

private struct DocumentFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    @MainActor func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DocumentProtocol.self]
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: configuration)
    }
}

private final class DocumentProtocol: URLProtocol {
    static var handler: ((DocumentProtocol) -> Void)?
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
