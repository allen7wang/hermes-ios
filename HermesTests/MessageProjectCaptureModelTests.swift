import XCTest
import UIKit
@testable import Hermes

final class MessageProjectCaptureModelTests: XCTestCase {
    override func tearDown() {
        ProjectCaptureURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor func testPreparationFreezesCompleteSourceAndExactTargetWithoutWriting() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget, fixture.archivedTarget], profileID: model.activeProfileID)
        let project = try XCTUnwrap(model.projects.first { $0.id == fixture.targetProjectID })
        let profiles = model.profiles
        let connections = try Data(contentsOf: fixture.connectionsURL)
        let history = try fixture.historyData()
        let drafts = try model.draftStore.snapshot()
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        XCTAssertEqual(capture.source.profileID, model.activeProfileID)
        XCTAssertEqual(capture.source.profileName, "采集连接")
        XCTAssertEqual(capture.source.items, source.items)
        XCTAssertEqual(capture.project, project)
        XCTAssertNotEqual(capture.project.id, fixture.sameNameProjectID)
        XCTAssertEqual(capture.project.name, model.projects.first { $0.id == fixture.sameNameProjectID }?.name)
        XCTAssertEqual(capture.source.items.first { $0.id == fixture.activeTarget }?.message.bookmark?.note, "私人收藏备注")
        XCTAssertNoThrow(try model.validateMessageProjectCapture(capture))
        XCTAssertEqual(model.profiles, profiles)
        XCTAssertEqual(try Data(contentsOf: fixture.connectionsURL), connections)
        XCTAssertEqual(try fixture.historyData(), history)
        XCTAssertEqual(try model.draftStore.snapshot(), drafts)
        XCTAssertEqual(model.selectedID, fixture.currentID)
        XCTAssertFalse(model.isSending)
    }

    @MainActor func testSaveAddsOneIndependentDocumentAndPreservesHistoryReferencesDraftsAndImages() throws {
        let fixture = try makeFixture(withImage: true)
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget, fixture.archivedTarget], profileID: model.activeProfileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let profiles = model.profiles
        let history = try fixture.historyData()
        let drafts = try model.draftStore.snapshot()
        let originalReferences = model.selectedConversation?.referenceDocumentIDs
        let imageURL = try XCTUnwrap(fixture.imageURL)
        let image = try Data(contentsOf: imageURL)
        let body = try MessageProjectCaptureText.initialBody(source) + "\n\n编辑补充：保留这份审阅后的材料。"
        let id = try model.saveMessageProjectCapture(capture, title: "  已审阅的汇编  ", body: body)
        let target = try XCTUnwrap(model.projects.first { $0.id == fixture.targetProjectID })
        let saved = try XCTUnwrap(target.documents.first { $0.id == id })
        XCTAssertEqual(saved.title, "已审阅的汇编")
        XCTAssertEqual(saved.body, body)
        XCTAssertTrue(saved.body.contains("来源消息的正文"))
        XCTAssertTrue(saved.body.contains("归档消息的正文"))
        XCTAssertTrue(saved.body.contains("图片未包含在此汇编中"))
        XCTAssertFalse(saved.body.contains("私人收藏备注"))
        XCTAssertEqual(Array(target.documents.dropLast()), capture.project.documents)
        XCTAssertFalse(capture.project.documents.contains { $0.id == id })
        XCTAssertEqual(target.createdAt, capture.project.createdAt)
        XCTAssertEqual(target.name, capture.project.name)
        XCTAssertEqual(target.summary, capture.project.summary)
        XCTAssertEqual(target.instructions, capture.project.instructions)
        XCTAssertGreaterThanOrEqual(target.updatedAt, capture.project.updatedAt)
        for profile in profiles {
            let actual = try XCTUnwrap(model.profiles.first { $0.id == profile.id })
            XCTAssertEqual(actual.name, profile.name)
            XCTAssertEqual(actual.serverURL, profile.serverURL)
            for project in profile.projects where project.id != fixture.targetProjectID {
                XCTAssertEqual(actual.projects.first { $0.id == project.id }, project)
            }
        }
        XCTAssertEqual(try fixture.historyData(), history)
        XCTAssertEqual(try model.draftStore.snapshot(), drafts)
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, originalReferences)
        XCTAssertFalse(model.currentReferenceDocuments.contains { $0.id == id })
        XCTAssertEqual(try Data(contentsOf: imageURL), image)
        XCTAssertEqual(model.selectedID, fixture.currentID)
        XCTAssertEqual(model.draft, "当前草稿")
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(fixture.model().projects.first { $0.id == fixture.targetProjectID }?.documents.first { $0.id == id }, saved)
    }

    @MainActor func testActiveUnassignedAndArchivedSourcesCanUseAnySameConnectionProject() throws {
        for scenario in ["crossProject", "unassigned", "archived"] {
            let fixture = try makeFixture()
            let model = fixture.model()
            let sourceTarget: LocalMessageTarget
            let projectID: UUID
            switch scenario {
            case "crossProject": sourceTarget = fixture.activeTarget; projectID = fixture.targetProjectID
            case "unassigned": sourceTarget = fixture.unassignedTarget; projectID = fixture.sameNameProjectID
            default: sourceTarget = fixture.archivedTarget; projectID = fixture.sourceProjectID
            }
            let source = try model.makeMessageLibraryBatch([sourceTarget], profileID: model.activeProfileID)
            let capture = try model.prepareMessageProjectCapture(source: source, projectID: projectID)
            let id = try model.saveMessageProjectCapture(capture, title: "显式选择的目标", body: "经用户确认的正文")
            XCTAssertEqual(capture.project.id, projectID)
            XCTAssertTrue(try XCTUnwrap(model.projects.first { $0.id == projectID }).documents.contains { $0.id == id })
            XCTAssertEqual(model.libraryItem(sourceTarget), source.items.first)
            XCTAssertEqual(model.selectedID, fixture.currentID)
            XCTAssertFalse(model.isSending)
        }
    }

    @MainActor func testImageOnlySelectionCannotUseBookmarkNoteAsBodyButMixedTextSelectionCanPrepare() throws {
        let fixture = try makeFixture(sourceBody: " \n\t", withImage: true)
        let model = fixture.model()
        let imageOnly = try model.makeMessageLibraryBatch([fixture.activeTarget], profileID: model.activeProfileID)
        let before = model.profiles
        XCTAssertThrowsError(try model.prepareMessageProjectCapture(source: imageOnly, projectID: fixture.targetProjectID)) { error in
            guard case MessageProjectCaptureError.noText = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let mixed = try model.makeMessageLibraryBatch([fixture.activeTarget, fixture.unassignedTarget], profileID: model.activeProfileID)
        XCTAssertNoThrow(try model.prepareMessageProjectCapture(source: mixed, projectID: fixture.targetProjectID))
        XCTAssertEqual(model.profiles, before)
        XCTAssertEqual(model.draft, "当前草稿")
    }

    @MainActor func testMissingForeignTargetAndChangedConnectionRejectWithoutSaving() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let profileID = model.activeProfileID
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget], profileID: profileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        XCTAssertThrowsError(try model.prepareMessageProjectCapture(source: source, projectID: UUID()))
        XCTAssertThrowsError(try model.prepareMessageProjectCapture(source: source, projectID: fixture.foreignProjectID))
        model.selectProfile(fixture.foreignProfileID)
        let foreignSource = try model.makeMessageLibraryBatch([fixture.foreignTarget], profileID: fixture.foreignProfileID)
        let foreignProfiles = model.profiles
        XCTAssertThrowsError(try model.validateMessageProjectCapture(capture))
        XCTAssertThrowsError(try model.saveMessageProjectCapture(capture, title: "不能跨连接写入", body: "正文"))
        XCTAssertEqual(model.profiles, foreignProfiles)
        model.selectProfile(profileID)
        XCTAssertThrowsError(try model.prepareMessageProjectCapture(source: foreignSource, projectID: fixture.targetProjectID))
        _ = try model.saveProfile(id: profileID, name: "连接已重命名", connection: model.settings)
        let before = try Data(contentsOf: fixture.connectionsURL)
        XCTAssertThrowsError(try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID))
        XCTAssertThrowsError(try model.saveMessageProjectCapture(capture, title: "旧连接名", body: "正文"))
        XCTAssertEqual(try Data(contentsOf: fixture.connectionsURL), before)
    }

    @MainActor func testReloadedSourceBodyChangeRejectsPreparationValidationAndSaveOfOldSnapshot() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget, fixture.archivedTarget], profileID: model.activeProfileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        var records = try fixture.history()
        let index = try XCTUnwrap(records.firstIndex { $0.id == fixture.activeTarget.conversationID })
        let message = try XCTUnwrap(records[index].messages.first)
        records[index].messages[0] = ChatMessage(id: message.id, role: message.role, content: "同标识的新正文",
            createdAt: message.createdAt, imageID: message.imageID, bookmark: message.bookmark)
        try fixture.writeHistory(records)
        let reopened = fixture.model()
        let before = try Data(contentsOf: fixture.connectionsURL)
        XCTAssertThrowsError(try reopened.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID))
        XCTAssertThrowsError(try reopened.validateMessageProjectCapture(capture))
        XCTAssertThrowsError(try reopened.saveMessageProjectCapture(capture, title: "不应保存", body: "编辑输入"))
        XCTAssertEqual(try Data(contentsOf: fixture.connectionsURL), before)
        XCTAssertEqual(reopened.libraryItem(fixture.activeTarget)?.message.content, "同标识的新正文")
    }

    @MainActor func testSourceNoteTitleTagsArchiveProjectIdentityAndAvailabilityMustStillMatch() throws {
        for change in ["note", "title", "tags", "archive", "projectName", "projectAssignment", "trash", "delete"] {
            let fixture = try makeFixture()
            let model = fixture.model()
            if change == "projectAssignment" {
                try model.assignConversations([fixture.activeTarget.conversationID], toProject: fixture.targetProjectID, profileID: model.activeProfileID)
            }
            let source = try model.makeMessageLibraryBatch([fixture.activeTarget, fixture.archivedTarget], profileID: model.activeProfileID)
            let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
            switch change {
            case "note": try model.updateBookmarkNote(fixture.activeTarget, note: "不参与输出仍需重新检查的备注")
            case "title": model.rename(fixture.activeTarget.conversationID, to: "新的来源标题")
            case "tags":
                model.select(fixture.activeTarget.conversationID)
                try model.saveConversationSettings(title: "来源对话", tags: "新来源标签", configuration: model.conversationConfiguration,
                    expectedDraftKey: model.draftKey, profileID: model.activeProfileID)
                model.select(fixture.currentID)
            case "archive": try model.setArchived([fixture.activeTarget.conversationID], archived: true)
            case "projectName":
                _ = try model.saveProject(id: fixture.sourceProjectID, name: "来源项目新名称", summary: "来源说明", instructions: "来源指令", profileID: model.activeProfileID)
            case "projectAssignment":
                try model.assignConversations([fixture.activeTarget.conversationID], toProject: fixture.sameNameProjectID, profileID: model.activeProfileID)
            default:
                try model.deleteConversations([fixture.activeTarget.conversationID])
                if change == "delete" { try model.permanentlyDeleteConversations([fixture.activeTarget.conversationID]) }
            }
            let before = try Data(contentsOf: fixture.connectionsURL)
            XCTAssertThrowsError(try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID), change)
            XCTAssertThrowsError(try model.saveMessageProjectCapture(capture, title: "过期资料", body: "编辑输入"), change)
            XCTAssertEqual(try Data(contentsOf: fixture.connectionsURL), before, change)
        }
    }

    @MainActor func testTargetFullProjectSnapshotIncludesDocumentsMetadataDatesAndDeletion() throws {
        for change in ["name", "summary", "instructions", "document", "addDocument", "removeDocument", "date", "delete"] {
            let fixture = try makeFixture()
            var model = fixture.model()
            let source = try model.makeMessageLibraryBatch([fixture.activeTarget], profileID: model.activeProfileID)
            let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
            switch change {
            case "name", "summary", "instructions":
                _ = try model.saveProject(id: fixture.targetProjectID,
                    name: change == "name" ? "目标新名称" : capture.project.name,
                    summary: change == "summary" ? "新目标说明" : capture.project.summary,
                    instructions: change == "instructions" ? "新目标指令" : capture.project.instructions, profileID: model.activeProfileID)
            case "document":
                _ = try model.saveProjectDocument(id: fixture.targetDocumentID, projectID: fixture.targetProjectID,
                    title: "目标原资料", body: "目标资料的新正文", profileID: model.activeProfileID)
            case "addDocument":
                _ = try model.saveProjectDocument(id: nil, projectID: fixture.targetProjectID, title: "另一份新资料", body: "正文", profileID: model.activeProfileID)
            case "removeDocument": try model.deleteProjectDocument(fixture.targetDocumentID, projectID: fixture.targetProjectID, profileID: model.activeProfileID)
            case "date":
                var library = try JSONDecoder().decode(ConnectionLibrary.self, from: Data(contentsOf: fixture.connectionsURL))
                let profileIndex = try XCTUnwrap(library.profiles.firstIndex { $0.id == model.activeProfileID })
                var projects = library.profiles[profileIndex].projects
                let projectIndex = try XCTUnwrap(projects.firstIndex { $0.id == fixture.targetProjectID })
                projects[projectIndex].updatedAt = projects[projectIndex].updatedAt.addingTimeInterval(1)
                library.profiles[profileIndex].projects = projects
                try JSONEncoder().encode(library).write(to: fixture.connectionsURL)
                model = fixture.model()
            default: try model.deleteProject(fixture.targetProjectID, profileID: model.activeProfileID)
            }
            let before = try Data(contentsOf: fixture.connectionsURL)
            XCTAssertThrowsError(try model.validateMessageProjectCapture(capture), change)
            XCTAssertThrowsError(try model.saveMessageProjectCapture(capture, title: "不能覆盖新状态", body: "编辑输入"), change)
            XCTAssertEqual(try Data(contentsOf: fixture.connectionsURL), before, change)
        }
    }

    @MainActor func testOtherSameNameProjectAndUnrelatedDraftPinAndReferenceChangesDoNotBlockCapture() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget], profileID: model.activeProfileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let otherID = try model.saveProjectDocument(id: nil, projectID: fixture.sameNameProjectID,
            title: "同名项目的独立资料", body: "保留其他项目修改", profileID: model.activeProfileID)
        model.togglePin(fixture.activeTarget.conversationID)
        model.draft = "打开编辑器后继续输入的聊天草稿"
        try model.selectProjectDocuments([], conversationID: fixture.currentID, profileID: model.activeProfileID)
        model.newConversation()
        model.draft = "新对话草稿也要保留"
        XCTAssertNoThrow(try model.validateMessageProjectCapture(capture))
        let id = try model.saveMessageProjectCapture(capture, title: "目标不混淆", body: "保存到明确标识的项目")
        XCTAssertTrue(try XCTUnwrap(model.projects.first { $0.id == fixture.targetProjectID }).documents.contains { $0.id == id })
        XCTAssertTrue(try XCTUnwrap(model.projects.first { $0.id == fixture.sameNameProjectID }).documents.contains { $0.id == otherID })
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.draft, "新对话草稿也要保留")
        XCTAssertEqual(model.draftStore.text(for: DraftStore.localKey(profileID: model.activeProfileID, conversationID: fixture.currentID)), "打开编辑器后继续输入的聊天草稿")
        XCTAssertTrue((model.conversations.first { $0.id == fixture.currentID }?.referenceDocumentIDs ?? []).isEmpty)
    }

    @MainActor func testTwentiethDocumentIsAllowedAndTwentyFirstIsRejectedWithoutPartialSave() throws {
        let documents = (0..<19).map { ProjectDocument(title: "已有资料\($0)", body: "正文") }
        let fixture = try makeFixture(targetDocuments: documents)
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget], profileID: model.activeProfileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        _ = try model.saveMessageProjectCapture(capture, title: "第二十篇", body: "可保存的正文")
        XCTAssertEqual(model.projects.first { $0.id == fixture.targetProjectID }?.documents.count, 20)
        let full = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let before = try Data(contentsOf: fixture.connectionsURL)
        XCTAssertThrowsError(try model.saveMessageProjectCapture(full, title: "第二十一篇", body: "不能部分保存"))
        XCTAssertEqual(try Data(contentsOf: fixture.connectionsURL), before)
        XCTAssertEqual(model.projects.first { $0.id == fixture.targetProjectID }?.documents.count, 20)
    }

    @MainActor func testProjectCharacterBudgetAcceptsExactlyTwoHundredThousandThenRejectsOverflow() throws {
        var documents = (0..<9).map { ProjectDocument(title: "满篇资料\($0)", body: String(repeating: "字", count: 20_000)) }
        documents.append(ProjectDocument(title: "边界前一篇", body: String(repeating: "字", count: 19_999)))
        let fixture = try makeFixture(targetDocuments: documents)
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget], profileID: model.activeProfileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        _ = try model.saveMessageProjectCapture(capture, title: "恰好达到项目上限", body: "字")
        XCTAssertEqual(model.projects.first { $0.id == fixture.targetProjectID }?.documents.reduce(0) { $0 + $1.body.count }, 200_000)
        let full = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let before = model.profiles
        XCTAssertThrowsError(try model.saveMessageProjectCapture(full, title: "超过总字符量", body: "字"))
        XCTAssertEqual(model.profiles, before)
        XCTAssertEqual(fixture.model().projects.first { $0.id == fixture.targetProjectID }?.documents.count, 11)
    }

    @MainActor func testEditedDocumentValidationUsesEightyAndTwentyThousandCharacterLimits() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget], profileID: model.activeProfileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let before = model.profiles
        for (title, body) in [("", "正文"), ("多\n行", "正文"), (String(repeating: "字", count: 81), "正文"),
                              ("有效标题", " \n"), ("有效标题", String(repeating: "字", count: 20_001))] {
            XCTAssertThrowsError(try model.saveMessageProjectCapture(capture, title: title, body: body))
            XCTAssertEqual(model.profiles, before)
        }
        let title = String(repeating: "字", count: 80)
        let body = String(repeating: "👩🏽‍💻", count: 20_000)
        let id = try model.saveMessageProjectCapture(capture, title: title, body: body)
        let document = try XCTUnwrap(model.projects.first { $0.id == fixture.targetProjectID }?.documents.first { $0.id == id })
        XCTAssertEqual(document.title, title)
        XCTAssertEqual(document.body, body)
    }

    @MainActor func testFailedAtomicConnectionsWriteDoesNotPublishAndCorruptStorageBlocksCapture() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget], profileID: model.activeProfileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let before = model.profiles
        let original = try Data(contentsOf: fixture.connectionsURL)
        let history = try fixture.historyData()
        let drafts = try model.draftStore.snapshot()
        try FileManager.default.removeItem(at: fixture.connectionsURL)
        try FileManager.default.createDirectory(at: fixture.connectionsURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.saveMessageProjectCapture(capture, title: "写失败", body: "不能发布的正文"))
        XCTAssertEqual(model.profiles, before)
        XCTAssertEqual(try fixture.historyData(), history)
        XCTAssertEqual(try model.draftStore.snapshot(), drafts)
        try FileManager.default.removeItem(at: fixture.connectionsURL)
        try original.write(to: fixture.connectionsURL)
        XCTAssertEqual(fixture.model().profiles, before)
        let corrupt = Data("unreadable connection data".utf8)
        try corrupt.write(to: fixture.connectionsURL)
        let recovery = fixture.model()
        XCTAssertTrue(recovery.needsRecovery)
        XCTAssertThrowsError(try recovery.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID))
        XCTAssertThrowsError(try recovery.validateMessageProjectCapture(capture))
        XCTAssertThrowsError(try recovery.saveMessageProjectCapture(capture, title: "不能覆盖损坏文件", body: "正文"))
        XCTAssertEqual(try Data(contentsOf: fixture.connectionsURL), corrupt)
    }

    @MainActor func testExplicitTargetRefreshCanSaveEditedInputButSourceRefreshAndDuplicateOldSaveAreRejected() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget], profileID: model.activeProfileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let editedTitle = "用户修改后保留的标题"
        let editedBody = "用户精简并补充的正文，不重置为初始消息汇编。"
        _ = try model.saveProjectDocument(id: fixture.targetDocumentID, projectID: fixture.targetProjectID,
            title: "目标原资料", body: "其他窗口保存了目标资料", profileID: model.activeProfileID)
        XCTAssertThrowsError(try model.saveMessageProjectCapture(capture, title: editedTitle, body: editedBody))
        let refreshed = try model.prepareMessageProjectCapture(source: capture.source, projectID: capture.project.id)
        XCTAssertNotEqual(refreshed.project, capture.project)
        let id = try model.saveMessageProjectCapture(refreshed, title: editedTitle, body: editedBody)
        let saved = try XCTUnwrap(model.projects.first { $0.id == fixture.targetProjectID }?.documents.first { $0.id == id })
        XCTAssertEqual(saved.title, editedTitle)
        XCTAssertEqual(saved.body, editedBody)
        let count = model.projects.first { $0.id == fixture.targetProjectID }?.documents.count
        XCTAssertThrowsError(try model.saveMessageProjectCapture(refreshed, title: editedTitle, body: editedBody))
        XCTAssertEqual(model.projects.first { $0.id == fixture.targetProjectID }?.documents.count, count)
        try model.updateBookmarkNote(fixture.activeTarget, note: "来源也发生变化")
        XCTAssertThrowsError(try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID))
    }

    @MainActor func testSavedCaptureUsesVersionSevenBackupAndRestoresDocumentDraftsReferencesAndImage() throws {
        let fixture = try makeFixture(withImage: true)
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget, fixture.unassignedTarget], profileID: model.activeProfileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let body = try MessageProjectCaptureText.initialBody(source)
        let id = try model.saveMessageProjectCapture(capture, title: "备份验证资料", body: body)
        let saved = try XCTUnwrap(model.projects.first { $0.id == fixture.targetProjectID }?.documents.first { $0.id == id })
        XCTAssertEqual(fixture.model().projects.first { $0.id == fixture.targetProjectID }?.documents.first { $0.id == id }, saved)
        let archive = try BackupArchive.decode(model.makeBackup().encoded())
        XCTAssertEqual(archive.version, 7)
        XCTAssertTrue(archive.profiles.flatMap(\.projects).flatMap(\.documents).contains(saved))
        let destination = try makeFixture(empty: true)
        let restored = destination.model()
        _ = try restored.importBackup(archive)
        let importedProfile = try XCTUnwrap(restored.profiles.first { $0.id != restored.activeProfileID && $0.name == "采集连接（已导入）" })
        restored.selectProfile(importedProfile.id)
        let target = try XCTUnwrap(restored.projects.first { $0.documents.contains { $0.title == "备份验证资料" } })
        XCTAssertEqual(target.documents.first { $0.title == "备份验证资料" }?.body, saved.body)
        let current = try XCTUnwrap(restored.conversations.first { $0.title == "当前聊天" })
        restored.select(current.id)
        XCTAssertEqual(restored.draft, "当前草稿")
        XCTAssertEqual(restored.currentReferenceDocuments.map(\.title), ["目标原资料"])
        XCTAssertFalse(restored.currentReferenceDocuments.contains { $0.title == "备份验证资料" })
        let sourceConversation = try XCTUnwrap(restored.conversations.first { $0.title == "来源对话" })
        XCTAssertEqual(sourceConversation.messages.first?.bookmark?.note, "私人收藏备注")
        let imageID = try XCTUnwrap(sourceConversation.messages.first?.imageID)
        XCTAssertNotNil(ImageAttachmentStore.image(imageID, directory: restored.attachmentDirectory))
        XCTAssertTrue(restored.projects.contains { $0.name == "来源项目" })
    }

    @MainActor func testFrozenCaptureAndReferenceRemovalPreserveEachOtherInEitherOrder() throws {
        for saveCaptureFirst in [true, false] {
            let documents = [ProjectDocument(title: "移除引用但保留资料", body: "原资料甲"),
                             ProjectDocument(title: "保留第二份引用", body: "原资料乙"),
                             ProjectDocument(title: "保留第一份引用", body: "原资料丙")]
            let fixture = try makeFixture(targetDocuments: documents)
            let model = fixture.model()
            let profileID = model.activeProfileID
            try model.selectProjectDocuments([documents[2].id, documents[0].id, documents[1].id],
                conversationID: fixture.currentID, profileID: profileID)
            let source = try model.makeMessageLibraryBatch([fixture.activeTarget, fixture.archivedTarget], profileID: profileID)
            let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
            let removal = try model.previewProjectReferenceRemoval(documentIDs: [documents[0].id],
                conversationIDs: [fixture.currentID], projectID: fixture.targetProjectID, profileID: profileID)
            let body = try MessageProjectCaptureText.initialBody(source) + "\n\n用户补充：组合操作后的资料正文。"
            let drafts = try model.draftStore.snapshot()
            var expectedHistory = try fixture.history()
            let currentIndex = try XCTUnwrap(expectedHistory.firstIndex { $0.id == fixture.currentID })
            let retainedIDs = [documents[2].id, documents[1].id]
            expectedHistory[currentIndex].referenceDocumentIDs = retainedIDs
            let newID: UUID
            if saveCaptureFirst {
                newID = try model.saveMessageProjectCapture(capture, title: "交错保存的新资料", body: body)
                try model.applyProjectReferenceRemoval(removal)
            } else {
                try model.applyProjectReferenceRemoval(removal)
                newID = try model.saveMessageProjectCapture(capture, title: "交错保存的新资料", body: body)
            }
            let target = try XCTUnwrap(model.projects.first { $0.id == fixture.targetProjectID })
            XCTAssertEqual(Array(target.documents.dropLast()), documents)
            XCTAssertEqual(target.documents.first { $0.id == newID }?.body, body)
            XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, retainedIDs)
            XCTAssertFalse((model.selectedConversation?.referenceDocumentIDs ?? []).contains(newID))
            XCTAssertEqual(try fixture.history(), expectedHistory)
            XCTAssertEqual(try model.draftStore.snapshot(), drafts)
            XCTAssertEqual(model.draft, "当前草稿")
            XCTAssertEqual(model.selectedID, fixture.currentID)
            XCTAssertFalse(model.isSending)
            let reopened = fixture.model()
            XCTAssertEqual(reopened.projects.first { $0.id == fixture.targetProjectID }?.documents, target.documents)
            XCTAssertEqual(reopened.selectedConversation?.referenceDocumentIDs, retainedIDs)
            XCTAssertEqual(reopened.draft, "当前草稿")
        }
    }

    @MainActor func testGenerationBlocksPreparationValidationAndSaveThenSameCaptureWorksAfterCompletion() async throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let source = try model.makeMessageLibraryBatch([fixture.activeTarget], profileID: model.activeProfileID)
        let capture = try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let started = expectation(description: "one controlled stream started")
        started.assertForOverFulfill = true
        var pending: ProjectCaptureURLProtocol?
        ProjectCaptureURLProtocol.handler = { pending = $0; started.fulfill() }
        XCTAssertTrue(model.send("当前聊天正在生成的问题"))
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(model.isSending)
        let before = model.profiles
        XCTAssertThrowsError(try model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID))
        XCTAssertThrowsError(try model.validateMessageProjectCapture(capture))
        XCTAssertThrowsError(try model.saveMessageProjectCapture(capture, title: "生成期间禁止保存", body: "正文"))
        XCTAssertEqual(model.profiles, before)
        model.draft = "生成期间继续输入的草稿"
        pending?.respond()
        for _ in 0..<150 where model.isSending { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.selectedConversation?.messages.last?.content, "继续完成的回复")
        _ = try model.saveMessageProjectCapture(capture, title: "生成结束后保存", body: "同一方案仍然有效")
        XCTAssertEqual(model.draft, "生成期间继续输入的草稿")
        XCTAssertEqual(model.selectedID, fixture.currentID)
    }

    @MainActor private func makeFixture(sourceBody: String = "来源消息的正文", withImage: Bool = false,
                                        targetDocuments: [ProjectDocument]? = nil, empty: Bool = false) throws -> ProjectCaptureFixture {
        let suite = "HermesProjectCaptureTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profileID = ConnectionProfile.legacyID
        let foreignProfileID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let sourceDocument = ProjectDocument(title: "来源项目资料", body: "来源项目已有的独立资料正文", createdAt: date, updatedAt: date)
        let documents = targetDocuments ?? [ProjectDocument(title: "目标原资料", body: "目标项目已有的独立资料正文", createdAt: date, updatedAt: date)]
        let firstTargetDocument = try XCTUnwrap(documents.first)
        let sourceProject = LocalProject(name: "来源项目", summary: "来源说明", instructions: "来源指令", createdAt: date, updatedAt: date, knowledgeDocuments: [sourceDocument])
        let targetProject = LocalProject(name: "同名目标", summary: "目标说明", instructions: "目标指令", createdAt: date, updatedAt: date, knowledgeDocuments: documents)
        let sameNameProject = LocalProject(name: "同名目标", summary: "另一个同名项目", instructions: "", createdAt: date, updatedAt: date)
        let foreignProject = LocalProject(name: "同名目标", summary: "其他连接项目", instructions: "", createdAt: date, updatedAt: date)
        let profiles = [ConnectionProfile(id: profileID, name: "采集连接", serverURL: "https://hermes.test/v1", model: "agent",
                                         localProjects: [sourceProject, targetProject, sameNameProject]),
                        ConnectionProfile(id: foreignProfileID, name: "其他连接", serverURL: "https://other.test/v1", model: "agent", localProjects: [foreignProject])]
        let keys = MemoryCredentials()
        keys.values["api-server-key"] = "project-capture-fixture-key"
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
        let activeMessage = ChatMessage(role: .assistant, content: sourceBody, createdAt: date, imageID: imageID,
            bookmark: MessageBookmark(createdAt: date, note: "私人收藏备注"))
        let active = Conversation(title: "来源对话", messages: [activeMessage], updatedAt: date, profileID: profileID,
            workspace: ConversationWorkspace(tags: ["来源标签"]), projectID: sourceProject.id, referenceDocumentIDs: [sourceDocument.id])
        let archivedMessage = ChatMessage(id: activeMessage.id, role: .user, content: "归档消息的正文", createdAt: date.addingTimeInterval(1))
        let archived = Conversation(title: "归档来源", messages: [archivedMessage], updatedAt: date, profileID: profileID,
            workspace: ConversationWorkspace(archived: true), projectID: sourceProject.id)
        let unassignedMessage = ChatMessage(role: .assistant, content: "未分组消息的正文", createdAt: date.addingTimeInterval(2))
        let unassigned = Conversation(title: "未分组来源", messages: [unassignedMessage], updatedAt: date, profileID: profileID)
        let current = Conversation(title: "当前聊天", messages: [ChatMessage(role: .user, content: "当前问题"), ChatMessage(role: .assistant, content: "当前回答")],
            updatedAt: date.addingTimeInterval(3), profileID: profileID, projectID: targetProject.id, referenceDocumentIDs: [firstTargetDocument.id])
        let trashMessage = ChatMessage(role: .assistant, content: "回收站原文")
        let trash = Conversation(title: "回收站", messages: [trashMessage], updatedAt: date, profileID: profileID,
            workspace: ConversationWorkspace(trashedAt: date), projectID: sourceProject.id, referenceDocumentIDs: [sourceDocument.id])
        let foreignMessage = ChatMessage(role: .assistant, content: "其他连接原文")
        let foreign = Conversation(title: "其他连接聊天", messages: [foreignMessage], updatedAt: date, profileID: foreignProfileID, projectID: foreignProject.id)
        let records = empty ? [] : [active, archived, unassigned, current, trash, foreign]
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("conversations.json"))
        let selections = empty ? [:] : [profileID.uuidString: current.id.uuidString, foreignProfileID.uuidString: foreign.id.uuidString]
        let library = ConnectionLibrary(profiles: profiles, activeID: profileID, selectedConversations: selections)
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"))
        let drafts = empty ? [:] : [DraftStore.localKey(profileID: profileID, conversationID: current.id): "当前草稿",
                                    DraftStore.localKey(profileID: profileID, conversationID: active.id): "来源草稿",
                                    DraftStore.localKey(profileID: profileID, conversationID: archived.id): "归档草稿",
                                    DraftStore.localKey(profileID: foreignProfileID, conversationID: foreign.id): "其他连接草稿"]
        try JSONEncoder().encode(drafts).write(to: directory.appendingPathComponent("drafts.json"))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return ProjectCaptureFixture(defaults: defaults, directory: directory, keys: keys, currentID: current.id,
            sourceProjectID: sourceProject.id, targetProjectID: targetProject.id, sameNameProjectID: sameNameProject.id,
            foreignProfileID: foreignProfileID, foreignProjectID: foreignProject.id, targetDocumentID: firstTargetDocument.id,
            activeTarget: .init(conversationID: active.id, messageID: activeMessage.id),
            archivedTarget: .init(conversationID: archived.id, messageID: archivedMessage.id),
            unassignedTarget: .init(conversationID: unassigned.id, messageID: unassignedMessage.id),
            foreignTarget: .init(conversationID: foreign.id, messageID: foreignMessage.id), imageURL: imageURL)
    }
}

private struct ProjectCaptureFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    let currentID: UUID
    let sourceProjectID: UUID
    let targetProjectID: UUID
    let sameNameProjectID: UUID
    let foreignProfileID: UUID
    let foreignProjectID: UUID
    let targetDocumentID: UUID
    let activeTarget: LocalMessageTarget
    let archivedTarget: LocalMessageTarget
    let unassignedTarget: LocalMessageTarget
    let foreignTarget: LocalMessageTarget
    let imageURL: URL?
    var connectionsURL: URL { directory.appendingPathComponent("connections.json") }
    var historyURL: URL { directory.appendingPathComponent("conversations.json") }
    func historyData() throws -> Data { try Data(contentsOf: historyURL) }
    func history() throws -> [Conversation] { try JSONDecoder().decode([Conversation].self, from: historyData()) }
    func writeHistory(_ records: [Conversation]) throws { try JSONEncoder().encode(records).write(to: historyURL) }
    @MainActor func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectCaptureURLProtocol.self]
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: configuration)
    }
}

private final class ProjectCaptureURLProtocol: URLProtocol {
    static var handler: ((ProjectCaptureURLProtocol) -> Void)?
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
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"继续完成的回复\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
