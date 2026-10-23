import XCTest
import UIKit
@testable import Hermes

final class MessageDraftQuoteModelTests: XCTestCase {
    override func tearDown() {
        DraftQuoteURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor func testPreparingSnapshotIsReadOnlyAndFreezesSourceAndDestination() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let projectID = try model.saveProject(id: nil, name: "当前项目", summary: "", instructions: "", profileID: model.activeProfileID)
        try model.assignConversations([fixture.currentID], toProject: projectID, profileID: model.activeProfileID)
        let history = try fixture.historyData()
        let drafts = try model.draftStore.snapshot()
        let connections = try Data(contentsOf: fixture.connectionsURL)
        let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget, fixture.archivedTarget], profileID: model.activeProfileID)
        XCTAssertEqual(snapshot.source.profileID, model.activeProfileID)
        XCTAssertEqual(snapshot.source.profileName, "引文测试")
        XCTAssertEqual(snapshot.source.items.map(\.id), [fixture.archivedTarget, fixture.sourceTarget])
        XCTAssertEqual(snapshot.source.items[0].message.id, snapshot.source.items[1].message.id)
        XCTAssertNotEqual(snapshot.source.items[0].id, snapshot.source.items[1].id)
        XCTAssertEqual(snapshot.draftKey, model.draftKey)
        XCTAssertEqual(snapshot.draftText, "当前草稿")
        XCTAssertEqual(snapshot.destination.conversationID, fixture.currentID)
        XCTAssertEqual(snapshot.destination.title, "当前聊天")
        XCTAssertEqual(snapshot.destination.projectID, projectID)
        XCTAssertEqual(snapshot.destination.projectName, "当前项目")
        XCTAssertNoThrow(try model.validateMessageDraftQuote(snapshot))
        XCTAssertEqual(model.draft, "当前草稿")
        XCTAssertEqual(try model.draftStore.snapshot(), drafts)
        XCTAssertEqual(try fixture.historyData(), history)
        XCTAssertEqual(try Data(contentsOf: fixture.connectionsURL), connections)
        XCTAssertFalse(model.isSending)
    }

    @MainActor func testAppendWritesOnlyDestinationDraftAndKeepsFullSourcesImagesAndOtherProfiles() throws {
        let body = "## 完整来源\n\n" + String(repeating: "👨‍👩‍👧‍👦", count: 4_101) + "\n末尾保留  "
        let fixture = try makeFixture(sourceBody: body, withImage: true)
        let model = fixture.model()
        let snapshot = try model.makeMessageDraftQuote([fixture.archivedTarget, fixture.sourceTarget], profileID: model.activeProfileID)
        let history = try fixture.historyData()
        let connections = try Data(contentsOf: fixture.connectionsURL)
        let drafts = try model.draftStore.snapshot()
        let imageURL = try XCTUnwrap(fixture.imageURL)
        let image = try Data(contentsOf: imageURL)
        try model.applyMessageDraftQuote(snapshot, mode: .append)
        XCTAssertTrue(model.draft.hasPrefix("当前草稿\n\n> # 引文测试"))
        XCTAssertTrue(model.draft.contains("> ## 完整来源\n> \n> " + String(repeating: "👨‍👩‍👧‍👦", count: 4_101)))
        XCTAssertTrue(model.draft.contains("> 末尾保留  "))
        XCTAssertTrue(model.draft.contains("图片未包含在此汇编中"))
        XCTAssertTrue(model.draft.contains("归档消息的正文"))
        XCTAssertFalse(model.draft.contains("绝不引用的私人备注"))
        XCTAssertFalse(model.draft.contains("引用已截取"))
        XCTAssertEqual(model.selectedID, fixture.currentID)
        XCTAssertFalse(model.isSending)
        var expectedDrafts = drafts
        expectedDrafts[snapshot.draftKey] = model.draft
        XCTAssertEqual(try model.draftStore.snapshot(), expectedDrafts)
        XCTAssertEqual(try fixture.historyData(), history)
        XCTAssertEqual(try Data(contentsOf: fixture.connectionsURL), connections)
        XCTAssertEqual(try Data(contentsOf: imageURL), image)
        let reopened = fixture.model()
        XCTAssertEqual(reopened.draft, model.draft)
        XCTAssertEqual(reopened.selectedID, fixture.currentID)
        reopened.select(fixture.sourceTarget.conversationID)
        XCTAssertEqual(reopened.draft, "来源对话的草稿")
        reopened.selectProfile(fixture.foreignProfileID)
        XCTAssertEqual(reopened.draft, "其他连接的草稿")
    }

    @MainActor func testReplaceAndAppendRespectEmptyAndWhitespaceOnlyOriginalDrafts() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        for original in ["替换前的文字", "", " \n  "] {
            for mode in PromptDraftMode.allCases {
                model.draft = original
                let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID)
                let reference = try MessageDraftQuote.referenceText(snapshot.source)
                try model.applyMessageDraftQuote(snapshot, mode: mode)
                let expected = mode == .replace || original.isEmpty ? reference : original + "\n\n" + reference
                XCTAssertEqual(model.draft, expected)
                XCTAssertEqual(model.draftStore.text(for: snapshot.draftKey), expected)
            }
        }
    }

    @MainActor func testNewConversationDraftCanReceiveQuoteWithoutCreatingOrSelectingHistory() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        model.newConversation()
        model.draft = "尚未创建的聊天"
        let history = try fixture.historyData()
        let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID)
        XCTAssertNil(snapshot.destination.conversationID)
        XCTAssertNil(snapshot.destination.projectID)
        XCTAssertNil(snapshot.destination.projectName)
        XCTAssertEqual(snapshot.draftKey, DraftStore.localKey(profileID: model.activeProfileID, conversationID: nil))
        try model.applyMessageDraftQuote(snapshot, mode: .append)
        XCTAssertTrue(model.draft.hasPrefix("尚未创建的聊天\n\n> #"))
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(try fixture.historyData(), history)
        let reopened = fixture.model()
        XCTAssertNil(reopened.selectedID)
        XCTAssertEqual(reopened.draft, model.draft)
    }

    @MainActor func testInvalidSourceSelectionsAndProfileCannotPrepareQuoteOrChangeDraft() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let before = try model.draftStore.snapshot()
        let invalidSelections: [[LocalMessageTarget]] = [
            [], [fixture.sourceTarget, fixture.sourceTarget], [fixture.sourceTarget, fixture.trashTarget],
            [fixture.sourceTarget, fixture.foreignTarget],
            [fixture.sourceTarget, .init(conversationID: fixture.sourceTarget.conversationID, messageID: UUID())]
        ]
        for targets in invalidSelections {
            XCTAssertThrowsError(try model.makeMessageDraftQuote(targets, profileID: model.activeProfileID))
        }
        XCTAssertThrowsError(try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: fixture.foreignProfileID))
        XCTAssertEqual(model.draft, "当前草稿")
        XCTAssertEqual(try model.draftStore.snapshot(), before)
        XCTAssertEqual(model.selectedID, fixture.currentID)
    }

    @MainActor func testArchivedDestinationIsRejectedAtPreparationAndAgainAtCommit() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        model.select(fixture.archivedTarget.conversationID)
        let archivedDraft = model.draft
        XCTAssertThrowsError(try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID))
        XCTAssertEqual(model.draft, archivedDraft)
        model.select(fixture.currentID)
        let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID)
        try model.setArchived([fixture.currentID], archived: true)
        let before = try model.draftStore.snapshot()
        XCTAssertThrowsError(try model.validateMessageDraftQuote(snapshot))
        XCTAssertThrowsError(try model.applyMessageDraftQuote(snapshot, mode: .replace))
        XCTAssertEqual(try model.draftStore.snapshot(), before)
        XCTAssertEqual(model.draft, "当前草稿")
    }

    @MainActor func testReloadedChangedSourceBodyRejectsOriginalSnapshotWithoutWritingDraft() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget, fixture.archivedTarget], profileID: model.activeProfileID)
        var records = try fixture.history()
        let conversationIndex = try XCTUnwrap(records.firstIndex { $0.id == fixture.sourceTarget.conversationID })
        let messageIndex = try XCTUnwrap(records[conversationIndex].messages.firstIndex { $0.id == fixture.sourceTarget.messageID })
        let original = records[conversationIndex].messages[messageIndex]
        records[conversationIndex].messages[messageIndex] = ChatMessage(id: original.id, role: original.role,
            content: "相同标识但正文已改变", createdAt: original.createdAt, imageID: original.imageID, bookmark: original.bookmark)
        try fixture.writeHistory(records)
        let reopened = fixture.model()
        let before = try reopened.draftStore.snapshot()
        XCTAssertThrowsError(try reopened.validateMessageDraftQuote(snapshot))
        XCTAssertThrowsError(try reopened.applyMessageDraftQuote(snapshot, mode: .append))
        XCTAssertEqual(reopened.draft, "当前草稿")
        XCTAssertEqual(try reopened.draftStore.snapshot(), before)
        XCTAssertEqual(reopened.libraryItem(fixture.sourceTarget)?.message.content, "相同标识但正文已改变")
    }

    @MainActor func testChangedSourceNoteMetadataOrAvailabilityRejectsEntireQuote() throws {
        for change in ["note", "title", "tags", "archive", "projectName", "projectAssignment", "trash", "delete"] {
            let fixture = try makeFixture()
            let model = fixture.model()
            let projectID = try model.saveProject(id: nil, name: "同名来源项目", summary: "", instructions: "", profileID: model.activeProfileID)
            try model.assignConversations([fixture.sourceTarget.conversationID], toProject: projectID, profileID: model.activeProfileID)
            let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget, fixture.archivedTarget], profileID: model.activeProfileID)
            switch change {
            case "note": try model.updateBookmarkNote(fixture.sourceTarget, note: "即使不输出也需重新检查的备注")
            case "title": model.rename(fixture.sourceTarget.conversationID, to: "新的来源名称")
            case "tags":
                model.select(fixture.sourceTarget.conversationID)
                try model.saveConversationSettings(title: "来源对话", tags: "新标签", configuration: model.conversationConfiguration,
                    expectedDraftKey: model.draftKey, profileID: model.activeProfileID)
                model.select(fixture.currentID)
            case "archive": try model.setArchived([fixture.sourceTarget.conversationID], archived: true)
            case "projectName":
                _ = try model.saveProject(id: projectID, name: "已改名来源项目", summary: "", instructions: "", profileID: model.activeProfileID)
            case "projectAssignment":
                let secondID = try model.saveProject(id: nil, name: "同名来源项目", summary: "", instructions: "", profileID: model.activeProfileID)
                try model.assignConversations([fixture.sourceTarget.conversationID], toProject: secondID, profileID: model.activeProfileID)
            default:
                try model.deleteConversations([fixture.sourceTarget.conversationID])
                if change == "delete" { try model.permanentlyDeleteConversations([fixture.sourceTarget.conversationID]) }
            }
            let before = try model.draftStore.snapshot()
            XCTAssertThrowsError(try model.validateMessageDraftQuote(snapshot), change)
            XCTAssertThrowsError(try model.applyMessageDraftQuote(snapshot, mode: .replace), change)
            XCTAssertEqual(try model.draftStore.snapshot(), before, change)
            XCTAssertEqual(model.selectedID, fixture.currentID, change)
            XCTAssertEqual(model.draft, "当前草稿", change)
        }
    }

    @MainActor func testDestinationSwitchRenameAndSameNameProjectChangesRejectOldSnapshot() throws {
        for change in ["selection", "newConversation", "title", "projectName", "projectAssignment", "trash"] {
            let fixture = try makeFixture()
            let model = fixture.model()
            let projectID = try model.saveProject(id: nil, name: "同名目标项目", summary: "", instructions: "", profileID: model.activeProfileID)
            try model.assignConversations([fixture.currentID], toProject: projectID, profileID: model.activeProfileID)
            let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID)
            switch change {
            case "selection": model.select(fixture.sourceTarget.conversationID)
            case "newConversation": model.newConversation()
            case "title": model.rename(fixture.currentID, to: "重命名目标对话")
            case "projectName":
                _ = try model.saveProject(id: projectID, name: "目标项目新名称", summary: "", instructions: "", profileID: model.activeProfileID)
            case "projectAssignment":
                let secondID = try model.saveProject(id: nil, name: "同名目标项目", summary: "", instructions: "", profileID: model.activeProfileID)
                try model.assignConversations([fixture.currentID], toProject: secondID, profileID: model.activeProfileID)
            default: try model.deleteConversations([fixture.currentID])
            }
            let before = try model.draftStore.snapshot()
            let currentDraft = model.draft
            XCTAssertThrowsError(try model.validateMessageDraftQuote(snapshot), change)
            XCTAssertThrowsError(try model.applyMessageDraftQuote(snapshot, mode: .append), change)
            XCTAssertEqual(model.draft, currentDraft, change)
            XCTAssertEqual(try model.draftStore.snapshot(), before, change)
        }
    }

    @MainActor func testDraftConflictAndConnectionSwitchOrRenameNeverOverwriteNewInput() throws {
        for change in ["draft", "profile", "profileName"] {
            let fixture = try makeFixture()
            let model = fixture.model()
            let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID)
            switch change {
            case "draft": model.draft = "检查页打开后继续输入的新文字"
            case "profile": model.selectProfile(fixture.foreignProfileID)
            default: _ = try model.saveProfile(id: model.activeProfileID, name: "新连接名", connection: model.settings)
            }
            let before = try model.draftStore.snapshot()
            let text = model.draft
            for mode in PromptDraftMode.allCases {
                XCTAssertThrowsError(try model.applyMessageDraftQuote(snapshot, mode: mode), change)
                XCTAssertEqual(model.draft, text, change)
                XCTAssertEqual(try model.draftStore.snapshot(), before, change)
            }
        }
    }

    @MainActor func testUnrelatedPinsSettingsAndProjectInstructionsDoNotInvalidateQuote() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let projectID = try model.saveProject(id: nil, name: "项目名称不变", summary: "旧说明", instructions: "旧指令", profileID: model.activeProfileID)
        try model.assignConversations([fixture.currentID, fixture.sourceTarget.conversationID], toProject: projectID, profileID: model.activeProfileID)
        let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID)
        model.togglePin(fixture.sourceTarget.conversationID)
        var configuration = model.conversationConfiguration
        configuration.systemPrompt = "新的目标聊天指令"
        try model.saveConversationSettings(title: "当前聊天", tags: "新的目标标签", configuration: configuration,
            expectedDraftKey: model.draftKey, profileID: model.activeProfileID)
        _ = try model.saveProject(id: projectID, name: "项目名称不变", summary: "新说明", instructions: "新指令", profileID: model.activeProfileID)
        XCTAssertNoThrow(try model.validateMessageDraftQuote(snapshot))
        try model.applyMessageDraftQuote(snapshot, mode: .append)
        XCTAssertTrue(model.draft.contains("来源消息的正文"))
        XCTAssertEqual(model.conversationConfiguration.systemPrompt, "新的目标聊天指令")
        XCTAssertEqual(model.selectedConversation?.workspaceState.tags, ["新的目标标签"])
        XCTAssertTrue(try XCTUnwrap(model.conversations.first { $0.id == fixture.sourceTarget.conversationID }).isPinned)
    }

    @MainActor func testAppendOverflowRejectsWithoutWriteButSameSnapshotCanReplace() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        model.draft = String(repeating: "字", count: 100_000)
        let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID)
        let before = try Data(contentsOf: fixture.draftsURL)
        XCTAssertNoThrow(try model.validateMessageDraftQuote(snapshot))
        XCTAssertThrowsError(try model.applyMessageDraftQuote(snapshot, mode: .append))
        XCTAssertEqual(model.draft, snapshot.draftText)
        XCTAssertEqual(try Data(contentsOf: fixture.draftsURL), before)
        try model.applyMessageDraftQuote(snapshot, mode: .replace)
        XCTAssertTrue(model.draft.hasPrefix("> # 引文测试"))
        XCTAssertLessThan(model.draft.count, 100_000)
        XCTAssertEqual(fixture.model().draft, model.draft)
    }

    @MainActor func testOversizedReferenceRefusesBothModesWithoutTruncatingSourceOrDraft() throws {
        let body = String(repeating: "字", count: 100_001)
        let fixture = try makeFixture(sourceBody: body)
        let model = fixture.model()
        let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID)
        let drafts = try model.draftStore.snapshot()
        let history = try fixture.historyData()
        for mode in PromptDraftMode.allCases {
            XCTAssertThrowsError(try model.applyMessageDraftQuote(snapshot, mode: mode))
        }
        XCTAssertEqual(model.libraryItem(fixture.sourceTarget)?.message.content, body)
        XCTAssertEqual(model.draft, "当前草稿")
        XCTAssertEqual(try model.draftStore.snapshot(), drafts)
        XCTAssertEqual(try fixture.historyData(), history)
    }

    @MainActor func testFailedDraftWriteDoesNotPublishOrLoseOtherDraftsAndRecoveryBlocksMutation() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID)
        let data = try Data(contentsOf: fixture.draftsURL)
        let before = try model.draftStore.snapshot()
        let history = try fixture.historyData()
        try FileManager.default.removeItem(at: fixture.draftsURL)
        try FileManager.default.createDirectory(at: fixture.draftsURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.applyMessageDraftQuote(snapshot, mode: .replace))
        XCTAssertEqual(model.draft, "当前草稿")
        XCTAssertEqual(try model.draftStore.snapshot(), before)
        XCTAssertEqual(try fixture.historyData(), history)
        try FileManager.default.removeItem(at: fixture.draftsURL)
        try data.write(to: fixture.draftsURL)
        XCTAssertEqual(fixture.model().draft, "当前草稿")
        let corrupt = Data("unreadable draft data".utf8)
        try corrupt.write(to: fixture.draftsURL)
        let recoveryModel = fixture.model()
        XCTAssertTrue(recoveryModel.needsRecovery)
        XCTAssertThrowsError(try recoveryModel.makeMessageDraftQuote([fixture.sourceTarget], profileID: recoveryModel.activeProfileID))
        XCTAssertThrowsError(try recoveryModel.validateMessageDraftQuote(snapshot))
        XCTAssertThrowsError(try recoveryModel.applyMessageDraftQuote(snapshot, mode: .append))
        XCTAssertEqual(try Data(contentsOf: fixture.draftsURL), corrupt)
    }

    @MainActor func testQuotedDraftUsesExistingBackupFormatAndRestoresAsDestinationDraft() throws {
        let fixture = try makeFixture(withImage: true)
        let model = fixture.model()
        let version = try model.makeBackup().version
        let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget, fixture.archivedTarget], profileID: model.activeProfileID)
        try model.applyMessageDraftQuote(snapshot, mode: .append)
        let quotedDraft = model.draft
        let archive = try BackupArchive.decode(model.makeBackup().encoded())
        XCTAssertEqual(archive.version, version)
        XCTAssertEqual(archive.drafts[snapshot.draftKey], quotedDraft)
        XCTAssertEqual(archive.bookmarkCount, 1)
        let destination = try makeFixture(empty: true)
        let restored = destination.model()
        _ = try restored.importBackup(archive)
        let importedProfile = try XCTUnwrap(restored.profiles.first {
            $0.id != restored.activeProfileID && $0.name == "引文测试（已导入）"
        })
        XCTAssertEqual(importedProfile.name, snapshot.source.profileName + "（已导入）")
        restored.selectProfile(importedProfile.id)
        let importedConversation = try XCTUnwrap(restored.conversations.first { $0.title == "当前聊天" })
        restored.select(importedConversation.id)
        XCTAssertEqual(restored.draft, quotedDraft)
        XCTAssertEqual(restored.conversations.first { $0.title == "来源对话" }?.messages.first?.bookmark?.note, "绝不引用的私人备注")
        let imageID = try XCTUnwrap(restored.conversations.first { $0.title == "来源对话" }?.messages.first?.imageID)
        XCTAssertNotNil(ImageAttachmentStore.image(imageID, directory: restored.attachmentDirectory))
    }

    @MainActor func testFrozenQuoteAndProjectReferenceAdditionBothSucceedInEitherOrder() throws {
        for addReferencesFirst in [true, false] {
            let fixture = try makeFixture()
            let model = fixture.model()
            let profileID = model.activeProfileID
            let projectID = try model.saveProject(id: nil, name: "组合整理项目", summary: "", instructions: "只用于请求上下文的项目指令", profileID: profileID)
            try model.assignConversations([fixture.currentID], toProject: projectID, profileID: profileID)
            let existingBody = "已选择资料的正文，不应混入消息引用草稿。"
            let addedBody = "新添加资料的正文，也不应混入消息引用草稿。"
            let existingID = try model.saveProjectDocument(id: nil, projectID: projectID,
                title: "已有参考资料", body: existingBody, profileID: profileID)
            let addedID = try model.saveProjectDocument(id: nil, projectID: projectID,
                title: "新增参考资料", body: addedBody, profileID: profileID)
            try model.selectProjectDocuments([existingID], conversationID: fixture.currentID, profileID: profileID)
            let originalMessages = model.selectedConversation?.messages
            let originalSource = model.libraryItem(fixture.sourceTarget)
            let quote = try model.makeMessageDraftQuote([fixture.sourceTarget, fixture.archivedTarget], profileID: profileID)
            let references = try model.previewProjectReferenceAddition(documentIDs: [addedID], conversationIDs: [fixture.currentID],
                projectID: projectID, profileID: profileID)
            let expectedDraft = quote.draftText + "\n\n" + (try MessageDraftQuote.referenceText(quote.source))
            if addReferencesFirst {
                try model.applyProjectReferenceAddition(references)
                try model.applyMessageDraftQuote(quote, mode: .append)
            } else {
                try model.applyMessageDraftQuote(quote, mode: .append)
                try model.applyProjectReferenceAddition(references)
            }
            XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, [existingID, addedID])
            XCTAssertEqual(model.currentReferenceDocuments.map(\.body), [existingBody, addedBody])
            XCTAssertEqual(model.draft, expectedDraft)
            XCTAssertTrue(model.draft.contains("来源消息的正文"))
            XCTAssertTrue(model.draft.contains("归档消息的正文"))
            XCTAssertFalse(model.draft.contains(existingBody))
            XCTAssertFalse(model.draft.contains(addedBody))
            XCTAssertFalse(model.draft.contains("只用于请求上下文的项目指令"))
            XCTAssertEqual(model.selectedConversation?.messages, originalMessages)
            XCTAssertEqual(model.libraryItem(fixture.sourceTarget), originalSource)
            XCTAssertEqual(model.selectedID, fixture.currentID)
            XCTAssertFalse(model.isSending)
            let reopened = fixture.model()
            XCTAssertEqual(reopened.selectedConversation?.referenceDocumentIDs, [existingID, addedID])
            XCTAssertEqual(reopened.draft, expectedDraft)
        }
    }

    @MainActor func testApplyingDuringGenerationDoesNotSendAgainAndCompletionKeepsPreparedDraft() async throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let started = expectation(description: "one controlled stream started")
        started.assertForOverFulfill = true
        var pending: DraftQuoteURLProtocol?
        DraftQuoteURLProtocol.handler = { pending = $0; started.fulfill() }
        XCTAssertTrue(model.send("原先已经发送的问题"))
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(model.isSending)
        model.draft = "回复期间编写的下一条问题"
        let snapshot = try model.makeMessageDraftQuote([fixture.sourceTarget], profileID: model.activeProfileID)
        try model.applyMessageDraftQuote(snapshot, mode: .append)
        let quotedDraft = model.draft
        XCTAssertTrue(model.isSending)
        XCTAssertEqual(model.selectedID, fixture.currentID)
        XCTAssertTrue(quotedDraft.hasPrefix("回复期间编写的下一条问题\n\n> #"))
        pending?.respond()
        for _ in 0..<150 where model.isSending { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.selectedConversation?.messages.last?.content, "先前问题的回复")
        XCTAssertEqual(model.draft, quotedDraft)
        XCTAssertEqual(fixture.model().draft, quotedDraft)
        XCTAssertEqual(model.draftStore.text(for: DraftStore.localKey(profileID: model.activeProfileID, conversationID: fixture.sourceTarget.conversationID)), "来源对话的草稿")
    }

    @MainActor private func makeFixture(sourceBody: String = "来源消息的正文", withImage: Bool = false, empty: Bool = false) throws -> DraftQuoteFixture {
        let suite = "HermesDraftQuoteTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profileID = ConnectionProfile.legacyID
        let foreignProfileID = UUID()
        let profiles = [ConnectionProfile(id: profileID, name: "引文测试", serverURL: "https://hermes.test/v1", model: "agent"),
                        ConnectionProfile(id: foreignProfileID, name: "其他连接", serverURL: "https://other.test/v1", model: "agent")]
        let keys = MemoryCredentials()
        keys.values["api-server-key"] = "quote-fixture-key"
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
        let message = ChatMessage(role: .assistant, content: sourceBody, createdAt: Date(timeIntervalSince1970: 100), imageID: imageID,
            bookmark: MessageBookmark(createdAt: Date(timeIntervalSince1970: 200), note: "绝不引用的私人备注"))
        let source = Conversation(title: "来源对话", messages: [message], updatedAt: Date(timeIntervalSince1970: 300), profileID: profileID,
            workspace: ConversationWorkspace(tags: ["来源标签"]))
        let archivedMessage = ChatMessage(id: message.id, role: .user, content: "归档消息的正文", createdAt: Date(timeIntervalSince1970: 101))
        let archived = Conversation(title: "归档来源", messages: [archivedMessage], updatedAt: Date(timeIntervalSince1970: 301), profileID: profileID,
            workspace: ConversationWorkspace(archived: true))
        let current = Conversation(title: "当前聊天", messages: [ChatMessage(role: .user, content: "当前问题"), ChatMessage(role: .assistant, content: "当前回答")],
            updatedAt: Date(timeIntervalSince1970: 302), profileID: profileID)
        let trashMessage = ChatMessage(role: .assistant, content: "回收站原文")
        let trash = Conversation(title: "回收站", messages: [trashMessage], updatedAt: Date(timeIntervalSince1970: 303), profileID: profileID,
            workspace: ConversationWorkspace(trashedAt: Date(timeIntervalSince1970: 400)))
        let foreignMessage = ChatMessage(id: message.id, role: .assistant, content: "其他连接的原文")
        let foreign = Conversation(title: "其他连接聊天", messages: [foreignMessage], updatedAt: Date(timeIntervalSince1970: 304), profileID: foreignProfileID)
        let records = empty ? [] : [source, archived, current, trash, foreign]
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("conversations.json"))
        let selections = empty ? [:] : [profileID.uuidString: current.id.uuidString, foreignProfileID.uuidString: foreign.id.uuidString]
        let library = ConnectionLibrary(profiles: profiles, activeID: profileID, selectedConversations: selections)
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"))
        let drafts = empty ? [:] : [DraftStore.localKey(profileID: profileID, conversationID: current.id): "当前草稿",
                                    DraftStore.localKey(profileID: profileID, conversationID: source.id): "来源对话的草稿",
                                    DraftStore.localKey(profileID: profileID, conversationID: archived.id): "归档来源的草稿",
                                    DraftStore.localKey(profileID: foreignProfileID, conversationID: foreign.id): "其他连接的草稿"]
        try JSONEncoder().encode(drafts).write(to: directory.appendingPathComponent("drafts.json"))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return DraftQuoteFixture(defaults: defaults, directory: directory, keys: keys, currentID: current.id, foreignProfileID: foreignProfileID,
            sourceTarget: .init(conversationID: source.id, messageID: message.id),
            archivedTarget: .init(conversationID: archived.id, messageID: archivedMessage.id),
            trashTarget: .init(conversationID: trash.id, messageID: trashMessage.id),
            foreignTarget: .init(conversationID: foreign.id, messageID: foreignMessage.id), imageURL: imageURL)
    }
}

private struct DraftQuoteFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    let currentID: UUID
    let foreignProfileID: UUID
    let sourceTarget: LocalMessageTarget
    let archivedTarget: LocalMessageTarget
    let trashTarget: LocalMessageTarget
    let foreignTarget: LocalMessageTarget
    let imageURL: URL?
    var historyURL: URL { directory.appendingPathComponent("conversations.json") }
    var draftsURL: URL { directory.appendingPathComponent("drafts.json") }
    var connectionsURL: URL { directory.appendingPathComponent("connections.json") }
    func historyData() throws -> Data { try Data(contentsOf: historyURL) }
    func history() throws -> [Conversation] { try JSONDecoder().decode([Conversation].self, from: historyData()) }
    func writeHistory(_ records: [Conversation]) throws { try JSONEncoder().encode(records).write(to: historyURL) }
    @MainActor func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DraftQuoteURLProtocol.self]
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: configuration)
    }
}

private final class DraftQuoteURLProtocol: URLProtocol {
    static var handler: ((DraftQuoteURLProtocol) -> Void)?
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
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"先前问题的回复\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
