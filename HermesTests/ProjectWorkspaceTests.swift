import XCTest
import UIKit
@testable import Hermes

final class ProjectWorkspaceTests: XCTestCase {
    override func tearDown() {
        ProjectProtocol.handler = nil
        ProjectProtocol.requests = 0
        super.tearDown()
    }

    func testLegacyProfilesAndConversationsDecodeWithoutProjectFields() throws {
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(#"{"id":"A7361652-066C-4601-B104-3ECA81739143","name":"旧连接","serverURL":"","model":"hermes-agent"}"#.utf8))
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"旧对话","messages":[],"updatedAt":0}"#.utf8))
        XCTAssertTrue(profile.projects.isEmpty)
        XCTAssertNil(conversation.projectID)
    }

    func testProjectValidationNormalizesInputAndRejectsUnboundedOrDuplicateRecords() throws {
        let valid = try LocalProject(name: "  发布  ", summary: "  说明  ", instructions: "  简洁回答  ").validated()
        XCTAssertEqual(valid.name, "发布"); XCTAssertEqual(valid.summary, "说明"); XCTAssertEqual(valid.instructions, "简洁回答")
        for project in [LocalProject(name: " ", summary: "", instructions: ""),
                        LocalProject(name: "多\n行", summary: "", instructions: ""),
                        LocalProject(name: String(repeating: "字", count: 61), summary: "", instructions: ""),
                        LocalProject(name: "项目", summary: String(repeating: "字", count: 2_001), instructions: ""),
                        LocalProject(name: "项目", summary: "", instructions: String(repeating: "字", count: 8_001))] {
            XCTAssertThrowsError(try project.validated())
        }
        XCTAssertThrowsError(try LocalProject.validateCollection([valid, valid]))
        XCTAssertThrowsError(try LocalProject.validateCollection((0...100).map { LocalProject(name: "项目\($0)", summary: "", instructions: "") }))
    }

    @MainActor func testProjectCRUDPersistsAndConnectionEditsPreserveIdentityWithoutCrossingEndpoints() throws {
        let f = try fixture(); let model = f.model(); let profileID = model.activeProfileID
        let id = try model.saveProject(id: nil, name: "  发布项目  ", summary: "本机说明", instructions: "用中文", profileID: profileID)
        let created = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(created.name, "发布项目")
        _ = try model.saveProject(id: id, name: "更新", summary: "新说明", instructions: "先给结论", profileID: profileID)
        XCTAssertEqual(model.projects.first?.createdAt, created.createdAt)
        XCTAssertEqual(f.model().projects, model.projects)
        _ = try model.saveProfile(id: profileID, name: "重命名连接", connection: model.settings)
        XCTAssertEqual(model.projects.first?.id, id)
        let other = try model.saveProfile(id: profileID, name: "新服务器", connection: .init(serverURL: "https://other.project.test/v1", model: "hermes-agent", apiKey: "fixture-key"))
        XCTAssertNotEqual(other, profileID); XCTAssertTrue(model.projects.isEmpty)
        XCTAssertThrowsError(try model.saveProject(id: id, name: "越界", summary: "", instructions: "", profileID: profileID))
        model.selectProfile(profileID); XCTAssertEqual(model.projects.first?.name, "更新")
    }

    @MainActor func testProjectSaveFailureKeepsPublishedAndStoredState() throws {
        let f = try fixture(); let model = f.model()
        let id = try model.saveProject(id: nil, name: "原项目", summary: "", instructions: "", profileID: model.activeProfileID)
        let before = model.projects
        let url = f.directory.appendingPathComponent("connections.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.saveProject(id: id, name: "未保存", summary: "", instructions: "", profileID: model.activeProfileID))
        XCTAssertEqual(model.projects, before)
        XCTAssertFalse(model.needsRecovery)
    }

    @MainActor func testStartingProjectConversationsCreatesIndependentDraftsWithoutSending() throws {
        let f = try fixture(); let model = f.model(); let originalID = try XCTUnwrap(model.selectedID)
        model.draft = "原对话草稿"
        let projectID = try model.saveProject(id: nil, name: "工作", summary: "", instructions: "", profileID: model.activeProfileID)
        let first = try model.startProjectConversation(projectID, profileID: model.activeProfileID)
        XCTAssertEqual(model.currentProject?.id, projectID); XCTAssertTrue(model.draft.isEmpty)
        XCTAssertEqual(model.selectedConversation?.title, "新对话"); XCTAssertTrue(model.selectedConversation!.messages.isEmpty)
        model.draft = "第一份草稿"
        let second = try model.startProjectConversation(projectID, profileID: model.activeProfileID)
        XCTAssertNotEqual(first, second); XCTAssertTrue(model.draft.isEmpty)
        model.draft = "第二份草稿"
        model.select(originalID); XCTAssertEqual(model.draft, "原对话草稿")
        model.select(first); XCTAssertEqual(model.draft, "第一份草稿")
        let reopened = f.model(); reopened.select(second); XCTAssertEqual(reopened.draft, "第二份草稿")
        XCTAssertEqual(ProjectProtocol.requests, 0)
    }

    @MainActor func testAssignmentsPreserveRecencyDraftAndArchiveAndRejectTrashOrForeignProjects() throws {
        let f = try fixture(); let model = f.model(); let ids = Set(model.conversations.map(\.id))
        let selected = try XCTUnwrap(model.selectedID); model.draft = "保留草稿"
        let project = try model.saveProject(id: nil, name: "项目", summary: "", instructions: "", profileID: model.activeProfileID)
        try model.setArchived([selected], archived: true)
        let before = model.conversations
        try model.assignConversations(ids, toProject: project, profileID: model.activeProfileID)
        XCTAssertTrue(model.conversations.allSatisfy { $0.projectID == project })
        XCTAssertEqual(model.conversations.map(\.updatedAt), before.map(\.updatedAt)); XCTAssertEqual(model.draft, "保留草稿")
        XCTAssertTrue(model.selectedConversation!.isArchived)
        let assigned = model.conversations
        XCTAssertThrowsError(try model.assignConversations(ids, toProject: UUID(), profileID: model.activeProfileID))
        XCTAssertEqual(model.conversations, assigned)
        try model.deleteConversations([selected])
        XCTAssertThrowsError(try model.assignConversations([selected], toProject: nil, profileID: model.activeProfileID))
        try model.restoreConversations([selected]); try model.assignConversations(ids, toProject: nil, profileID: model.activeProfileID)
        XCTAssertTrue(model.conversations.allSatisfy { $0.projectID == nil })
    }

    @MainActor func testSettingsSaveUpdatesMembershipTogetherAndRejectsInvalidProjectBeforeChangingSettings() throws {
        let f = try fixture(); let model = f.model()
        let project = try model.saveProject(id: nil, name: "项目", summary: "", instructions: "", profileID: model.activeProfileID)
        try model.saveConversationSettings(title: "更新标题", tags: "工作", configuration: .init(systemPrompt: "简洁"), expectedDraftKey: model.draftKey, profileID: model.activeProfileID, project: .project(project))
        XCTAssertEqual(model.selectedConversation?.title, "更新标题"); XCTAssertEqual(model.currentProject?.id, project)
        let before = model.selectedConversation
        XCTAssertThrowsError(try model.saveConversationSettings(title: "不应保存", tags: "", configuration: .init(), expectedDraftKey: model.draftKey, profileID: model.activeProfileID, project: .project(UUID())))
        XCTAssertEqual(model.selectedConversation, before)
        try model.saveConversationSettings(title: "保持归属", tags: "", configuration: .init(), expectedDraftKey: model.draftKey, profileID: model.activeProfileID)
        XCTAssertEqual(model.currentProject?.id, project)
        try model.saveConversationSettings(title: "解除归属", tags: "", configuration: .init(), expectedDraftKey: model.draftKey, profileID: model.activeProfileID, project: .unassigned)
        XCTAssertNil(model.currentProject)
    }

    @MainActor func testDissolvingProjectKeepsActiveArchivedTrashedRecordsImagesDraftsAndSelection() throws {
        let f = try fixture(image: true); let model = f.model(); let profileID = model.activeProfileID
        let project = try model.saveProject(id: nil, name: "项目", summary: "", instructions: "", profileID: profileID)
        let ids = Set(model.conversations.map(\.id)); try model.assignConversations(ids, toProject: project, profileID: profileID)
        let first = model.conversations[0].id; let second = model.conversations[1].id
        model.select(first); model.draft = "保留草稿"; try model.setArchived([second], archived: true)
        let third = try model.startProjectConversation(project, profileID: profileID)
        model.draft = "回收站草稿"; try model.deleteConversations([third]); model.select(first)
        let before = try model.makeBackup(); let selectedID = model.selectedID
        try model.deleteProject(project, profileID: profileID)
        let after = try model.makeBackup()
        XCTAssertEqual(after.images, before.images); XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(model.selectedID, selectedID)
        XCTAssertEqual(model.draft, "保留草稿"); XCTAssertTrue(model.projects.isEmpty)
        XCTAssertEqual(after.conversations.map(\.messages), before.conversations.map(\.messages))
        XCTAssertEqual(after.conversations.map(\.updatedAt), before.conversations.map(\.updatedAt))
        XCTAssertTrue(after.conversations.allSatisfy { $0.projectID == nil })
        XCTAssertEqual(after.trashCount, 1); XCTAssertEqual(model.conversations.filter(\.isArchived).count, 1)
        XCTAssertTrue(f.model().projects.isEmpty)
    }

    @MainActor func testDissolveFailureBlocksWritesAndJournalRecoversConsistentRelationshipsOnRelaunch() throws {
        let f = try fixture(); let model = f.model()
        let project = try model.saveProject(id: nil, name: "项目", summary: "", instructions: "", profileID: model.activeProfileID)
        try model.assignConversations(Set(model.conversations.map(\.id)), toProject: project, profileID: model.activeProfileID)
        let before = model.conversations
        let draftURL = f.directory.appendingPathComponent("drafts.json")
        if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
        try FileManager.default.createDirectory(at: draftURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.deleteProject(project, profileID: model.activeProfileID))
        XCTAssertEqual(model.projects.first?.id, project); XCTAssertEqual(model.conversations, before); XCTAssertTrue(model.needsRecovery)
        try FileManager.default.removeItem(at: draftURL)
        let reopened = f.model(); XCTAssertFalse(reopened.needsRecovery); XCTAssertTrue(reopened.projects.isEmpty)
        XCTAssertTrue(reopened.conversations.allSatisfy { $0.projectID == nil })
    }

    @MainActor func testBranchKeepsProjectAndConfigurationWhileExcludingBookmarkMetadata() throws {
        let model = try fixture().model()
        let project = try model.saveProject(id: nil, name: "项目", summary: "", instructions: "项目指令", profileID: model.activeProfileID)
        try model.assignConversations([try XCTUnwrap(model.selectedID)], toProject: project, profileID: model.activeProfileID)
        let source = try XCTUnwrap(model.selectedConversation)
        XCTAssertTrue(model.branchConversation(at: source.messages.last!.id))
        XCTAssertNotEqual(model.selectedID, source.id); XCTAssertEqual(model.selectedConversation?.projectID, project)
        XCTAssertTrue(model.selectedConversation!.messages.allSatisfy { $0.bookmark == nil })
        XCTAssertEqual(model.selectedConversation?.workspaceState.configuration, source.workspaceState.configuration)
    }

    @MainActor func testBackupVersionSixRoundTripAndRepeatedForeignImportRemapRelationsWithoutOverwritingEdits() throws {
        let source = try fixture(image: true); let sourceModel = source.model()
        let sourceProject = try sourceModel.saveProject(id: nil, name: "原项目", summary: "说明", instructions: "原指令", profileID: sourceModel.activeProfileID)
        try sourceModel.assignConversations(Set(sourceModel.conversations.map(\.id)), toProject: sourceProject, profileID: sourceModel.activeProfileID)
        sourceModel.draft = "项目草稿"
        let archive = try BackupArchive.decode(sourceModel.makeBackup().encoded())
        XCTAssertEqual(archive.version, 6); XCTAssertEqual(archive.projectCount, 1)
        let destination = try fixture(empty: true); let model = destination.model()
        let report = try model.importBackup(archive); XCTAssertEqual(report.projectsAdded, 1)
        let profile = try XCTUnwrap(model.profiles.first { $0.id != model.activeProfileID }); model.selectProfile(profile.id)
        let importedProject = try XCTUnwrap(model.projects.first); XCTAssertNotEqual(importedProject.id, sourceProject)
        XCTAssertTrue(model.conversations.allSatisfy { $0.projectID == importedProject.id }); XCTAssertEqual(model.draft, "项目草稿")
        _ = try model.saveProject(id: importedProject.id, name: "本机编辑", summary: "本机说明", instructions: "本机指令", profileID: profile.id)
        let detached = try XCTUnwrap(model.selectedID); try model.assignConversations([detached], toProject: nil, profileID: profile.id)
        let before = model.conversations; let second = try model.importBackup(archive)
        XCTAssertEqual(second.projectsAdded, 0); XCTAssertEqual(second.conversationsAdded, 0)
        XCTAssertEqual(model.projects.first?.name, "本机编辑"); XCTAssertEqual(model.conversations, before)
        XCTAssertEqual(try model.makeBackup().projectCount, 1)
    }

    @MainActor func testVersionSixImportJournalRestoresProjectRelationsAfterInterruption() throws {
        let source = try fixture(); let sourceModel = source.model()
        let project = try sourceModel.saveProject(id: nil, name: "恢复项目", summary: "说明", instructions: "恢复指令", profileID: sourceModel.activeProfileID)
        try sourceModel.assignConversations(Set(sourceModel.conversations.map(\.id)), toProject: project, profileID: sourceModel.activeProfileID)
        sourceModel.draft = "恢复草稿"
        let archive = try sourceModel.makeBackup()
        let destination = try fixture(empty: true); let model = destination.model()
        let draftURL = destination.directory.appendingPathComponent("drafts.json")
        if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
        try FileManager.default.createDirectory(at: draftURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.importBackup(archive)); XCTAssertTrue(model.needsRecovery)
        try FileManager.default.removeItem(at: draftURL)
        let reopened = destination.model(); XCTAssertFalse(reopened.needsRecovery)
        let profile = try XCTUnwrap(reopened.profiles.first { !$0.projects.isEmpty }); reopened.selectProfile(profile.id)
        let importedProject = try XCTUnwrap(reopened.projects.first)
        XCTAssertTrue(reopened.conversations.allSatisfy { $0.projectID == importedProject.id })
        XCTAssertEqual(reopened.draft, "恢复草稿"); XCTAssertEqual(importedProject.instructions, "恢复指令")
    }

    @MainActor func testSameInstallationImportKeepsProjectIdentityAndLocalEdits() throws {
        let model = try fixture().model()
        let project = try model.saveProject(id: nil, name: "备份项目", summary: "", instructions: "备份指令", profileID: model.activeProfileID)
        try model.assignConversations([try XCTUnwrap(model.selectedID)], toProject: project, profileID: model.activeProfileID)
        let archive = try model.makeBackup()
        _ = try model.saveProject(id: project, name: "本机新名字", summary: "本机说明", instructions: "本机指令", profileID: model.activeProfileID)
        let report = try model.importBackup(archive)
        XCTAssertEqual(report.profilesAdded, 0); XCTAssertEqual(report.projectsAdded, 0)
        XCTAssertEqual(model.projects.first?.id, project); XCTAssertEqual(model.currentProject?.instructions, "本机指令")
    }

    func testProjectBackupRejectsDowngradeOrOrphanedAndCrossConnectionMembership() throws {
        let project = LocalProject(name: "项目", summary: "", instructions: "")
        let profile = ConnectionProfile(name: "连接", serverURL: "", model: "hermes-agent", localProjects: [project])
        let conversation = Conversation(title: "对话", messages: [], updatedAt: Date(), profileID: profile.id, projectID: project.id)
        var archive = BackupArchive(version: 6, installationID: UUID(), createdAt: Date(), profiles: [profile], conversations: [conversation], drafts: [:], images: [:])
        try archive.validate()
        archive.version = 5; XCTAssertThrowsError(try archive.validate()); archive.version = 6
        archive.conversations[0].projectID = UUID(); XCTAssertThrowsError(try archive.validate())
        let other = ConnectionProfile(name: "其他", serverURL: "", model: "hermes-agent")
        archive.profiles.append(other); archive.conversations[0].projectID = project.id; archive.conversations[0].profileID = other.id
        XCTAssertThrowsError(try archive.validate())
        archive.conversations[0].profileID = profile.id; archive.profiles[0].projects = [project, project]
        XCTAssertThrowsError(try archive.validate())
    }

    func testIdenticalProjectIDsAcrossConnectionsAreRemappedSeparately() throws {
        let project = LocalProject(name: "同ID项目", summary: "", instructions: "")
        let first = ConnectionProfile(name: "A", serverURL: "https://a.project.test", model: "hermes-agent", localProjects: [project])
        let second = ConnectionProfile(name: "B", serverURL: "https://b.project.test", model: "hermes-agent", localProjects: [project])
        let records = [first, second].map { Conversation(title: $0.name, messages: [], updatedAt: Date(), profileID: $0.id, projectID: project.id) }
        let archive = BackupArchive(version: 6, installationID: UUID(), createdAt: Date(), profiles: [first, second], conversations: records, drafts: [:], images: [:])
        let empty = ConnectionProfile(name: "空", serverURL: "", model: "hermes-agent")
        let merge = try BackupMerge.prepare(archive, installationID: UUID(), library: .init(profiles: [empty], activeID: empty.id), conversations: [], drafts: [:])
        XCTAssertEqual(merge.report.projectsAdded, 2)
        let imported = merge.state.library.profiles.filter { !$0.projects.isEmpty }
        XCTAssertNotEqual(imported[0].projects[0].id, imported[1].projects[0].id)
        for conversation in merge.state.conversations {
            XCTAssertEqual(conversation.projectID, imported.first { $0.id == conversation.profileID }?.projects.first?.id)
        }
    }

    func testLegacyBackupVersionsStillValidateAndNoProjectDoesNotForceVersionSix() throws {
        let profile = ConnectionProfile(name: "旧连接", serverURL: "", model: "hermes-agent")
        for version in 1...5 {
            let archive = BackupArchive(version: version, installationID: UUID(), createdAt: Date(), profiles: [profile], conversations: [], drafts: [:], images: [:])
            XCTAssertEqual(try BackupArchive.decode(archive.encoded()).version, version)
            XCTAssertEqual(archive.minimumVersion, 1)
        }
    }

    @MainActor func testCorruptProjectRelationshipTriggersRecoveryWithoutOverwritingOriginalFiles() throws {
        let f = try fixture(); let recordsURL = f.directory.appendingPathComponent("conversations.json")
        var records = try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: recordsURL))
        records[0].projectID = UUID()
        let corrupt = try JSONEncoder().encode(records); try corrupt.write(to: recordsURL)
        let model = f.model(); XCTAssertTrue(model.needsRecovery)
        XCTAssertEqual(try Data(contentsOf: recordsURL), corrupt)
        XCTAssertThrowsError(try model.saveProject(id: nil, name: "不能写入", summary: "", instructions: "", profileID: model.activeProfileID))
    }

    func testProjectFilterCombinesWithWorkbenchScopesWithoutMutatingRecords() {
        let projectID = UUID()
        let assigned = Conversation(title: "工作计划", messages: [], updatedAt: Date(), workspace: .init(tags: ["工作"]), projectID: projectID)
        let unassigned = Conversation(title: "未分组", messages: [], updatedAt: Date())
        XCTAssertEqual(ConversationWorkbench.filtered([assigned, unassigned], scope: .active, query: "计划", tag: "工作", sort: .recent, project: .project(projectID)).map(\.id), [assigned.id])
        XCTAssertEqual(ConversationWorkbench.filtered([assigned, unassigned], scope: .active, query: "", tag: nil, sort: .recent, project: .unassigned).map(\.id), [unassigned.id])
    }

    func testPreparedContextCombinesBoundedInstructionsWithoutSendingSummaryOrUnrelatedMetadata() throws {
        let project = LocalProject(name: "不发送的名称", summary: "私密说明", instructions: String(repeating: "项", count: 8_000))
        let config = ConversationConfiguration(systemPrompt: String(repeating: "话", count: 10_000), contextTurns: 1)
        let context = try PreparedChatContext(messages: [ChatMessage(role: .user, content: "问题")], configuration: config, project: project)
        XCTAssertEqual(context.configuration, config)
        XCTAssertEqual(context.project, project)
        XCTAssertTrue(context.effectiveSystemPrompt.contains(project.instructions)); XCTAssertTrue(context.effectiveSystemPrompt.contains(config.systemPrompt))
        XCTAssertFalse(context.effectiveSystemPrompt.contains(project.summary)); XCTAssertFalse(context.effectiveSystemPrompt.contains(project.name))
        let legacy = try PreparedChatContext(messages: [], configuration: .init(systemPrompt: "原提示词"))
        XCTAssertEqual(legacy.effectiveSystemPrompt, "原提示词")
    }

    @MainActor func testActualRequestMatchesPreviewAndFirstSendNamesProjectConversation() async throws {
        let model = try fixture().model()
        let project = try model.saveProject(id: nil, name: "项目名不发送", summary: "项目私密说明", instructions: "项目统一用中文", profileID: model.activeProfileID)
        let conversationID = try model.startProjectConversation(project, profileID: model.activeProfileID)
        try model.saveConversationSettings(title: "新对话", tags: "", configuration: .init(systemPrompt: "会话简洁回答", contextTurns: 2), expectedDraftKey: model.draftKey, profileID: model.activeProfileID)
        model.draft = " 发布计划 "
        let preview = try model.previewNextRequest(model.draft, hasImage: false, expectedDraftKey: model.draftKey)
        let received = expectation(description: "project request")
        ProjectProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            XCTAssertEqual(messages.first?["role"] as? String, "system")
            XCTAssertEqual(messages.first?["content"] as? String, preview.plan.effectiveSystemPrompt)
            XCTAssertEqual(Array(messages.dropFirst()).compactMap { $0["content"] as? String }, preview.plan.messages.map(\.content))
            let wire = String(decoding: request.body, as: UTF8.self)
            XCTAssertFalse(wire.contains("项目私密说明")); XCTAssertFalse(wire.contains("项目名不发送")); XCTAssertFalse(wire.contains("原答案"))
            request.respond(); received.fulfill()
        }
        XCTAssertTrue(model.send(model.draft)); await fulfillment(of: [received], timeout: 3)
        for _ in 0..<150 where model.isSending { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.selectedID, conversationID); XCTAssertEqual(model.selectedConversation?.title, "发布计划")
        XCTAssertEqual(model.currentProject?.id, project); XCTAssertFalse(model.isSending)
    }

    @MainActor func testProjectMutationsAreBlockedWhileResponseIsRunning() async throws {
        let model = try fixture().model()
        let project = try model.saveProject(id: nil, name: "原项目", summary: "", instructions: "", profileID: model.activeProfileID)
        let received = expectation(description: "pending request"); var pending: ProjectProtocol?
        ProjectProtocol.handler = { pending = $0; received.fulfill() }
        XCTAssertTrue(model.send("等待")); await fulfillment(of: [received], timeout: 3)
        XCTAssertTrue(model.isSending)
        XCTAssertThrowsError(try model.saveProject(id: project, name: "不能改", summary: "", instructions: "", profileID: model.activeProfileID))
        XCTAssertThrowsError(try model.deleteProject(project, profileID: model.activeProfileID))
        XCTAssertThrowsError(try model.assignConversations([try XCTUnwrap(model.selectedID)], toProject: project, profileID: model.activeProfileID))
        XCTAssertThrowsError(try model.startProjectConversation(project, profileID: model.activeProfileID))
        pending?.respond()
        for _ in 0..<150 where model.isSending { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.projects.first?.name, "原项目")
    }

    @MainActor private func fixture(image: Bool = false, empty: Bool = false) throws -> ProjectFixture {
        let suite = "HermesProjectTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("https://project.hermes.test/v1", forKey: "serverURL"); defaults.set("default-model", forKey: "model")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var imageID: UUID?
        if image {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }.jpegData(compressionQuality: 0.8)!
            imageID = try ImageAttachmentStore.save(data, directory: directory.appendingPathComponent("Attachments"))
        }
        let records = [Conversation(title: "原对话", messages: [ChatMessage(role: .user, content: "原问题", imageID: imageID), ChatMessage(role: .assistant, content: "原答案", bookmark: .init(createdAt: Date(), note: "私密备注"))], updatedAt: Date(), workspace: .init(configuration: .init(systemPrompt: "原会话指令"))),
                       Conversation(title: "另一对话", messages: [], updatedAt: Date(timeIntervalSince1970: 1))]
        try JSONEncoder().encode(empty ? [] : records).write(to: directory.appendingPathComponent("conversations.json"))
        let keys = MemoryCredentials(); keys.values["api-server-key"] = "project-fixture-key"
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return ProjectFixture(defaults: defaults, directory: directory, keys: keys)
    }
}

private struct ProjectFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    @MainActor func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ProjectProtocol.self]
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: configuration)
    }
}

private final class ProjectProtocol: URLProtocol {
    static var handler: ((ProjectProtocol) -> Void)?
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
