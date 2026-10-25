import XCTest
@testable import Hermes

final class WorkspaceDiscoveryTests: XCTestCase {
    override func tearDown() {
        DiscoveryURLProtocol.handler = nil
        super.tearDown()
    }

    func testSearchFindsAllFiveKindsFromTheirCompleteSearchableFields() {
        let profileID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let document = ProjectDocument(title: "普通资料标题", body: "资料正文中的星河", createdAt: date, updatedAt: date)
        let project = LocalProject(name: "普通项目名称", summary: "项目简介中的星河", instructions: "", createdAt: date, updatedAt: date,
            knowledgeDocuments: [document])
        let message = ChatMessage(role: .assistant, content: "无关键词的消息正文", createdAt: date,
            bookmark: .init(createdAt: date, note: "收藏备注中的星河"))
        let conversation = Conversation(title: "普通对话名称", messages: [message], updatedAt: date, profileID: profileID,
            workspace: .init(tags: ["星河标签"]), projectID: project.id)
        let snapshot = WorkspaceDiscoverySnapshot(profileID: profileID, profileName: "当前连接", projects: [project], conversations: [conversation],
            drafts: [DraftStore.localKey(profileID: profileID, conversationID: conversation.id): "独立草稿中的星河"])
        let report = WorkspaceSearch.run(snapshot, query: "星河")
        XCTAssertEqual(report.total, 5)
        XCTAssertEqual(Set(report.results.map(\.kind)), Set(WorkspaceSearchKind.allCases))
        for kind in WorkspaceSearchKind.allCases { XCTAssertEqual(report.counts[kind], 1) }
        XCTAssertEqual(report.results.first { $0.kind == .message }?.destination,
            .message(.init(conversationID: conversation.id, messageID: message.id)))
        XCTAssertTrue(report.results.allSatisfy { $0.excerpt.contains("星河") })
    }

    func testLongUnicodeBodiesAndDraftsProduceAnExcerptAroundTheActualMatch() {
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 240) + "深处命中" + String(repeating: "👩🏽‍💻", count: 240)
        let snapshot = simpleSnapshot(text: text)
        let report = WorkspaceSearch.run(snapshot, query: "深处命中")
        XCTAssertEqual(report.total, 4)
        XCTAssertFalse(report.results.contains { $0.kind == .conversation })
        for result in report.results {
            XCTAssertTrue(result.excerpt.contains("深处命中"))
            XCTAssertTrue(result.excerpt.hasPrefix("…"))
            XCTAssertTrue(result.excerpt.hasSuffix("…"))
            XCTAssertLessThan(result.excerpt.count, 200)
            XCTAssertNotEqual(result.excerpt, String(text.prefix(160)))
        }
        XCTAssertEqual(snapshot.projects[0].documents[0].body, text)
        XCTAssertEqual(snapshot.conversations[0].messages[0].content, text)
    }

    func testSearchHandlesChineseEmojiCaseAndCanonicalDiacriticForms() {
        let snapshot = simpleSnapshot(text: "Café 中文 👩🏽‍💻")
        for query in ["cafe", "CAFÉ", "Cafe\u{301}", "中文", "👩🏽‍💻", " \nCAFÉ\t "] {
            XCTAssertEqual(WorkspaceSearch.run(snapshot, query: query).total, 5, query)
        }
        XCTAssertEqual(WorkspaceSearch.run(snapshot, query: "不存在").total, 0)
    }

    func testEmptyWhitespaceAndOverlongQueriesReturnNoResultsWhileTwoHundredCharactersWork() {
        let query = String(repeating: "字", count: 200)
        let snapshot = simpleSnapshot(text: query + "尾部")
        for invalid in ["", " \n\t\r\n", "\u{3000}", query + "字"] {
            let report = WorkspaceSearch.run(snapshot, query: invalid)
            XCTAssertEqual(report.total, 0)
            XCTAssertTrue(report.results.isEmpty)
        }
        XCTAssertEqual(WorkspaceSearch.run(snapshot, query: query).total, 4)
        XCTAssertEqual(WorkspaceSearch.run(snapshot, query: " \n" + query + "\t ").total, 4)
    }

    func testEachKindKeepsNewestFiftyButCountsAllMatchesWithStableOrdering() {
        let profileID = UUID()
        var projects: [LocalProject] = []
        var conversations: [Conversation] = []
        var drafts: [String: String] = [:]
        for index in 0..<65 {
            let date = Date(timeIntervalSince1970: Double(index))
            let document = ProjectDocument(title: "匹配资料", body: "正文", createdAt: date, updatedAt: date)
            let project = LocalProject(name: "匹配项目", summary: "", instructions: "", createdAt: date, updatedAt: date,
                knowledgeDocuments: [document])
            let conversation = Conversation(title: "匹配对话", messages: [.init(role: .user, content: "匹配消息", createdAt: date)],
                updatedAt: date, profileID: profileID, projectID: project.id)
            projects.append(project); conversations.append(conversation)
            drafts[DraftStore.localKey(profileID: profileID, conversationID: conversation.id)] = "匹配草稿"
        }
        let snapshot = WorkspaceDiscoverySnapshot(profileID: profileID, profileName: "当前", projects: projects, conversations: conversations, drafts: drafts)
        let report = WorkspaceSearch.run(snapshot, query: "匹配")
        XCTAssertEqual(report.total, 325)
        XCTAssertEqual(report.results.count, 250)
        for kind in WorkspaceSearchKind.allCases {
            XCTAssertEqual(report.counts[kind], 65)
            let matches = report.results.filter { $0.kind == kind }
            XCTAssertEqual(matches.count, 50)
            XCTAssertEqual(matches.map { $0.date.timeIntervalSince1970 }, (15..<65).reversed().map(Double.init))
        }
        let reversed = WorkspaceDiscoverySnapshot(profileID: profileID, profileName: "当前", projects: Array(projects.reversed()),
            conversations: Array(conversations.reversed()), drafts: drafts)
        XCTAssertEqual(report, WorkspaceSearch.run(reversed, query: "匹配"))
        XCTAssertEqual(report.results, report.results.sorted(by: WorkspaceDiscoverySnapshot.recent))
    }

    func testSameMessageUUIDInTwoConversationsHasIndependentStableCompositeResults() {
        let profileID = UUID()
        let shared = ChatMessage(role: .assistant, content: "组合标识", createdAt: Date(timeIntervalSince1970: 100))
        let first = Conversation(title: "第一段", messages: [shared], updatedAt: shared.createdAt, profileID: profileID)
        let second = Conversation(title: "第二段", messages: [shared], updatedAt: shared.createdAt, profileID: profileID)
        let snapshot = WorkspaceDiscoverySnapshot(profileID: profileID, profileName: "当前", projects: [], conversations: [first, second], drafts: [:])
        let report = WorkspaceSearch.run(snapshot, query: "组合标识")
        XCTAssertEqual(report.counts[.message], 2)
        XCTAssertEqual(Set(report.results.map(\.id)).count, 2)
        XCTAssertEqual(Set(report.results.map(\.destination)), [.message(.init(conversationID: first.id, messageID: shared.id)),
            .message(.init(conversationID: second.id, messageID: shared.id))])
        let reversed = WorkspaceDiscoverySnapshot(profileID: profileID, profileName: "当前", projects: [], conversations: [second, first], drafts: [:])
        XCTAssertEqual(report, WorkspaceSearch.run(reversed, query: "组合标识"))
        XCTAssertEqual(report.results.map(\.id), report.results.map(\.id).sorted())
    }

    @MainActor func testArchivedResultsRequireExplicitOptInAndTrashForeignRemoteAndOrphanDraftsStayExcluded() throws {
        let fixture = try makeFixture()
        let library = try fixture.library()
        let snapshot = WorkspaceDiscoverySnapshot(profileID: fixture.profileID, profileName: "探索连接",
            projects: library.profiles[0].projects, conversations: try fixture.history(), drafts: try fixture.drafts())
        let ordinary = WorkspaceSearch.run(snapshot, query: "星河")
        XCTAssertFalse(ordinary.results.contains { $0.archived })
        let includingArchive = WorkspaceSearch.run(snapshot, query: "星河", includeArchived: true)
        let archived = includingArchive.results.filter(\.archived)
        XCTAssertEqual(Set(archived.map(\.kind)), [.conversation, .message, .draft])
        XCTAssertEqual(archived.count, 3)
        XCTAssertEqual(includingArchive.total, ordinary.total + 3)
        for forbidden in ["跨连接", "回收站", "远端草稿", "孤儿草稿", "无效草稿"] {
            XCTAssertEqual(WorkspaceSearch.run(snapshot, query: forbidden, includeArchived: true).total, 0, forbidden)
        }
        XCTAssertFalse(snapshot.draftItems(includeArchived: true).contains { $0.destination == .draft(fixture.trashID) })
    }

    func testDraftListingPutsNewConversationFirstAndIgnoresWhitespaceDrafts() {
        let profileID = UUID()
        let older = Conversation(title: "旧聊天", messages: [], updatedAt: Date(timeIntervalSince1970: 10), profileID: profileID)
        let newer = Conversation(title: "新聊天", messages: [], updatedAt: Date(timeIntervalSince1970: 20), profileID: profileID)
        let blank = Conversation(title: "空白聊天", messages: [], updatedAt: .distantFuture, profileID: profileID)
        let snapshot = WorkspaceDiscoverySnapshot(profileID: profileID, profileName: "当前", projects: [], conversations: [older, blank, newer], drafts: [
            DraftStore.localKey(profileID: profileID, conversationID: older.id): "旧输入",
            DraftStore.localKey(profileID: profileID, conversationID: newer.id): "新输入",
            DraftStore.localKey(profileID: profileID, conversationID: blank.id): " \n\t\u{3000}",
            DraftStore.localKey(profileID: profileID, conversationID: nil): "未创建聊天的输入"
        ])
        XCTAssertEqual(snapshot.draftItems().map(\.destination), [.draft(nil), .draft(newer.id), .draft(older.id)])
        XCTAssertEqual(snapshot.draftItems()[0].title, "新对话草稿")
    }

    func testProjectConversationCountsAggregateActiveArchivedAndExcludeTrashAndUnassigned() {
        let profileID = UUID(), first = UUID(), second = UUID()
        let records = [
            Conversation(title: "进行中", messages: [], updatedAt: Date(), profileID: profileID, projectID: first),
            Conversation(title: "进行中二", messages: [], updatedAt: Date(), profileID: profileID, projectID: first),
            Conversation(title: "归档", messages: [], updatedAt: Date(), profileID: profileID, workspace: .init(archived: true), projectID: first),
            Conversation(title: "回收站归档", messages: [], updatedAt: Date(), profileID: profileID, workspace: .init(archived: true, trashedAt: Date()), projectID: first),
            Conversation(title: "另一项目", messages: [], updatedAt: Date(), profileID: profileID, projectID: second),
            Conversation(title: "未分组", messages: [], updatedAt: Date(), profileID: profileID)
        ]
        let counts = ProjectConversationCounts.aggregate(records)
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(counts[first], .init(active: 2, archived: 1))
        XCTAssertEqual(counts[second], .init(active: 1, archived: 0))
        XCTAssertTrue(ProjectConversationCounts.aggregate([]).isEmpty)
    }

    @MainActor func testSnapshotUsesCurrentUnwrittenInputAndCopiesOnlyCurrentLocalScope() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let originalData = try Data(contentsOf: fixture.draftsURL)
        try replaceWithDirectory(fixture.draftsURL)
        model.draft = "磁盘写入失败但仍在编辑器中的新文字"
        XCTAssertNotEqual(model.draftStore.text(for: model.draftKey), model.draft)
        let snapshot = try model.workspaceSnapshot()
        XCTAssertEqual(snapshot.drafts[model.draftKey], model.draft)
        XCTAssertTrue(snapshot.drafts.keys.allSatisfy { $0.hasPrefix("\(fixture.profileID.uuidString)/local/") })
        XCTAssertTrue(snapshot.conversations.allSatisfy { $0.profileID == fixture.profileID && !$0.isTrashed })
        XCTAssertEqual(snapshot.projects.map(\.id), [fixture.projectID])
        XCTAssertEqual(WorkspaceSearch.run(snapshot, query: "仍在编辑器").counts[.draft], 1)
        XCTAssertTrue(snapshot.draftItems().contains { $0.destination == .draft(fixture.currentID) && $0.excerpt.contains("仍在编辑器") })
        try FileManager.default.removeItem(at: fixture.draftsURL)
        try originalData.write(to: fixture.draftsURL)
    }

    @MainActor func testNavigationResolvesCompositeMessageAndPreservesEveryDraftWithoutSending() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let history = try fixture.historyData()
        model.draft = "离开当前聊天前的新输入"
        try model.openWorkspaceDestination(.message(fixture.otherTarget), profileID: fixture.profileID)
        XCTAssertEqual(model.selectedID, fixture.otherID)
        XCTAssertEqual(model.draft, "独立来源草稿")
        try model.openWorkspaceDestination(.draft(fixture.currentID), profileID: fixture.profileID)
        XCTAssertEqual(model.draft, "离开当前聊天前的新输入")
        try model.openWorkspaceDestination(.draft(nil), profileID: fixture.profileID)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.draft, "星河新草稿")
        try model.openWorkspaceDestination(.conversation(fixture.archivedID), profileID: fixture.profileID)
        XCTAssertEqual(model.selectedID, fixture.archivedID)
        XCTAssertTrue(model.selectedConversation?.isArchived == true)
        XCTAssertEqual(model.draft, "星河归档草稿")
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(try fixture.historyData(), history)
        let reopened = fixture.model()
        XCTAssertEqual(reopened.selectedID, fixture.archivedID)
        XCTAssertEqual(reopened.draft, "星河归档草稿")
        XCTAssertEqual(reopened.draftStore.text(for: DraftStore.localKey(profileID: fixture.profileID, conversationID: fixture.currentID)), "离开当前聊天前的新输入")
    }

    @MainActor func testStaleProfileTrashedDeletedAndMismatchedTargetsCannotNavigate() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let start = model.selectedID
        let text = model.draft
        let invalid: [WorkspaceDestination] = [.conversation(UUID()), .conversation(fixture.trashID), .conversation(fixture.foreignID),
            .message(.init(conversationID: fixture.otherID, messageID: UUID())),
            .message(.init(conversationID: fixture.foreignID, messageID: fixture.currentTarget.messageID)),
            .draft(fixture.orphanID), .draft(fixture.trashID), .draft(fixture.foreignID)]
        for target in invalid {
            XCTAssertThrowsError(try model.openWorkspaceDestination(target, profileID: fixture.profileID))
            XCTAssertEqual(model.selectedID, start)
            XCTAssertEqual(model.draft, text)
        }
        try model.deleteConversations([fixture.otherID])
        XCTAssertThrowsError(try model.openWorkspaceDestination(.message(fixture.otherTarget), profileID: fixture.profileID))
        try model.permanentlyDeleteConversations([fixture.otherID])
        XCTAssertThrowsError(try model.openWorkspaceDestination(.conversation(fixture.otherID), profileID: fixture.profileID))
        model.selectProfile(fixture.foreignProfileID)
        let foreignDraft = model.draft
        XCTAssertThrowsError(try model.openWorkspaceDestination(.conversation(fixture.currentID), profileID: fixture.profileID))
        XCTAssertEqual(model.activeProfileID, fixture.foreignProfileID)
        XCTAssertEqual(model.draft, foreignDraft)
    }

    @MainActor func testProjectAndDocumentNavigationOnlyValidateAndNeverSwitchCurrentChat() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let drafts = try model.draftStore.snapshot()
        let history = try fixture.historyData()
        try model.openWorkspaceDestination(.project(fixture.projectID), profileID: fixture.profileID)
        try model.openWorkspaceDestination(.document(projectID: fixture.projectID, documentID: fixture.documentID), profileID: fixture.profileID)
        XCTAssertEqual(model.selectedID, fixture.currentID)
        XCTAssertEqual(model.draft, "星河当前草稿")
        XCTAssertEqual(try model.draftStore.snapshot(), drafts)
        XCTAssertEqual(try fixture.historyData(), history)
        XCTAssertThrowsError(try model.openWorkspaceDestination(.project(fixture.foreignProjectID), profileID: fixture.profileID))
        XCTAssertThrowsError(try model.openWorkspaceDestination(.document(projectID: fixture.foreignProjectID, documentID: fixture.documentID), profileID: fixture.profileID))
        try model.deleteProjectDocument(fixture.documentID, projectID: fixture.projectID, profileID: fixture.profileID)
        XCTAssertThrowsError(try model.openWorkspaceDestination(.document(projectID: fixture.projectID, documentID: fixture.documentID), profileID: fixture.profileID))
        try model.deleteProject(fixture.projectID, profileID: fixture.profileID)
        XCTAssertThrowsError(try model.openWorkspaceDestination(.project(fixture.projectID), profileID: fixture.profileID))
        XCTAssertEqual(model.selectedID, fixture.currentID)
    }

    @MainActor func testDiscoveryNavigationAndStartRefuseToLeaveAnUnwrittenDraft() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let original = try Data(contentsOf: fixture.draftsURL)
        try replaceWithDirectory(fixture.draftsURL)
        model.draft = "尚未成功保存的重要输入"
        for target in [WorkspaceDestination.conversation(fixture.otherID), .message(fixture.otherTarget), .draft(nil)] {
            XCTAssertThrowsError(try model.openWorkspaceDestination(target, profileID: fixture.profileID))
            XCTAssertEqual(model.selectedID, fixture.currentID)
            XCTAssertEqual(model.draft, "尚未成功保存的重要输入")
        }
        XCTAssertThrowsError(try model.startWorkspaceConversation(profileID: fixture.profileID))
        XCTAssertEqual(model.selectedID, fixture.currentID)
        try FileManager.default.removeItem(at: fixture.draftsURL)
        try original.write(to: fixture.draftsURL)
        try model.openWorkspaceDestination(.conversation(fixture.otherID), profileID: fixture.profileID)
        XCTAssertEqual(model.draft, "独立来源草稿")
        XCTAssertEqual(model.draftStore.text(for: DraftStore.localKey(profileID: fixture.profileID, conversationID: fixture.currentID)), "尚未成功保存的重要输入")
        XCTAssertEqual(fixture.model().selectedID, fixture.otherID)
    }

    @MainActor func testStartNewConversationRetainsBothOldAndExistingNewDraftWithoutCreatingHistory() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let history = try fixture.historyData()
        model.draft = "原聊天继续编辑的输入"
        try model.startWorkspaceConversation(profileID: fixture.profileID)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.draft, "星河新草稿")
        XCTAssertEqual(model.draftStore.text(for: DraftStore.localKey(profileID: fixture.profileID, conversationID: fixture.currentID)), "原聊天继续编辑的输入")
        model.draft = "当前的新对话编辑文字"
        try model.startWorkspaceConversation(profileID: fixture.profileID)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.draft, "当前的新对话编辑文字")
        XCTAssertEqual(try fixture.historyData(), history)
        XCTAssertThrowsError(try model.startWorkspaceConversation(profileID: fixture.foreignProfileID))
        XCTAssertEqual(fixture.model().draft, "当前的新对话编辑文字")
    }

    @MainActor func testLegacySelectionNewConversationAndProfileSwitchProtectUnwrittenInput() throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let original = try Data(contentsOf: fixture.draftsURL)
        try replaceWithDirectory(fixture.draftsURL)
        model.draft = "旧入口也必须保留的未写入文字"
        XCTAssertTrue(model.select(fixture.currentID))
        XCTAssertTrue(model.selectProfile(fixture.profileID))
        XCTAssertEqual(model.draft, "旧入口也必须保留的未写入文字")
        XCTAssertFalse(model.select(fixture.otherID))
        XCTAssertFalse(model.newConversation())
        XCTAssertFalse(model.selectProfile(fixture.foreignProfileID))
        XCTAssertEqual(model.selectedID, fixture.currentID)
        XCTAssertEqual(model.activeProfileID, fixture.profileID)
        XCTAssertEqual(model.draft, "旧入口也必须保留的未写入文字")
        try FileManager.default.removeItem(at: fixture.draftsURL)
        try original.write(to: fixture.draftsURL)
        XCTAssertTrue(model.select(fixture.otherID))
        XCTAssertEqual(model.draft, "独立来源草稿")
        XCTAssertEqual(model.draftStore.text(for: DraftStore.localKey(profileID: fixture.profileID, conversationID: fixture.currentID)), "旧入口也必须保留的未写入文字")
        XCTAssertTrue(model.newConversation())
        XCTAssertEqual(model.draft, "星河新草稿")
        XCTAssertTrue(model.selectProfile(fixture.foreignProfileID))
        XCTAssertEqual(model.draft, "星河跨连接草稿")
        XCTAssertTrue(model.selectProfile(fixture.profileID))
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.draft, "星河新草稿")
    }

    @MainActor func testDiscoveryIsEphemeralAndExistingBackupRestoresDraftsAndSearchableContent() throws {
        let fixture = try makeFixture(includeOrphans: false)
        let model = fixture.model()
        let before = try model.makeBackup()
        let snapshot = try model.workspaceSnapshot()
        XCTAssertGreaterThan(WorkspaceSearch.run(snapshot, query: "星河").total, 0)
        try model.openWorkspaceDestination(.message(fixture.otherTarget), profileID: fixture.profileID)
        try model.startWorkspaceConversation(profileID: fixture.profileID)
        let archive = try BackupArchive.decode(model.makeBackup().encoded())
        XCTAssertEqual(archive.version, before.version)
        XCTAssertEqual(archive.version, 7)
        XCTAssertEqual(archive.conversations, before.conversations)
        XCTAssertEqual(archive.profiles, before.profiles)
        XCTAssertEqual(archive.drafts, before.drafts)
        let destination = try makeFixture(empty: true, includeOrphans: false)
        let restored = destination.model()
        _ = try restored.importBackup(archive)
        let imported = try XCTUnwrap(restored.profiles.first { $0.id != restored.activeProfileID && $0.name == "探索连接（已导入）" })
        restored.selectProfile(imported.id)
        let current = try XCTUnwrap(restored.conversations.first { $0.title == "星河主对话" })
        try restored.openWorkspaceDestination(.draft(current.id), profileID: imported.id)
        XCTAssertEqual(restored.draft, "星河当前草稿")
        XCTAssertEqual(restored.currentReferenceDocuments.map(\.title), ["研究资料"])
        XCTAssertGreaterThan(WorkspaceSearch.run(try restored.workspaceSnapshot(), query: "星河").total, 0)
        XCTAssertFalse(restored.isSending)
    }

    @MainActor func testCorruptDraftStorageBlocksSnapshotNavigationAndNewConversationWithoutReplacement() throws {
        let fixture = try makeFixture()
        let corrupt = Data("unreadable drafts".utf8)
        try corrupt.write(to: fixture.draftsURL)
        let model = fixture.model()
        XCTAssertTrue(model.needsRecovery)
        XCTAssertThrowsError(try model.workspaceSnapshot())
        XCTAssertThrowsError(try model.openWorkspaceDestination(.project(fixture.projectID), profileID: fixture.profileID))
        XCTAssertThrowsError(try model.openWorkspaceDestination(.conversation(fixture.otherID), profileID: fixture.profileID))
        XCTAssertThrowsError(try model.startWorkspaceConversation(profileID: fixture.profileID))
        XCTAssertEqual(try Data(contentsOf: fixture.draftsURL), corrupt)
    }

    @MainActor func testGenerationAllowsReadOnlySnapshotButBlocksDiscoveryNavigation() async throws {
        let fixture = try makeFixture()
        let model = fixture.model()
        let started = expectation(description: "one controlled request")
        started.assertForOverFulfill = true
        var pending: DiscoveryURLProtocol?
        DiscoveryURLProtocol.handler = { pending = $0; started.fulfill() }
        XCTAssertTrue(model.send("新问题"))
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(model.isSending)
        XCTAssertNoThrow(try model.workspaceSnapshot())
        XCTAssertThrowsError(try model.openWorkspaceDestination(.conversation(fixture.otherID), profileID: fixture.profileID))
        XCTAssertThrowsError(try model.startWorkspaceConversation(profileID: fixture.profileID))
        XCTAssertEqual(model.selectedID, fixture.currentID)
        pending?.respond()
        for _ in 0..<150 where model.isSending { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.selectedConversation?.messages.last?.content, "探索测试回复")
    }

    private func simpleSnapshot(text: String) -> WorkspaceDiscoverySnapshot {
        let profileID = UUID(), date = Date(timeIntervalSince1970: 100)
        let document = ProjectDocument(title: "资料标题", body: text, createdAt: date, updatedAt: date)
        let project = LocalProject(name: "项目名称", summary: text, instructions: "", createdAt: date, updatedAt: date, knowledgeDocuments: [document])
        let conversation = Conversation(title: "对话标题", messages: [.init(role: .assistant, content: text, createdAt: date)], updatedAt: date,
            profileID: profileID, workspace: .init(tags: text.count <= 20 ? [text] : []), projectID: project.id)
        return .init(profileID: profileID, profileName: "当前", projects: [project], conversations: [conversation],
            drafts: [DraftStore.localKey(profileID: profileID, conversationID: conversation.id): text])
    }

    private func replaceWithDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    @MainActor private func makeFixture(empty: Bool = false, includeOrphans: Bool = true) throws -> DiscoveryFixture {
        let suite = "HermesDiscoveryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profileID = ConnectionProfile.legacyID, foreignProfileID = UUID(), orphanID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let document = ProjectDocument(title: "研究资料", body: String(repeating: "前", count: 230) + "星河资料正文", createdAt: date, updatedAt: date)
        let project = LocalProject(name: "探索计划", summary: "星河项目简介", instructions: "不发送检索请求", createdAt: date, updatedAt: date,
            knowledgeDocuments: [document])
        let foreignProject = LocalProject(name: "星河跨连接项目", summary: "", instructions: "", createdAt: date, updatedAt: date)
        let profiles = [ConnectionProfile(id: profileID, name: "探索连接", serverURL: "https://hermes.test/v1", model: "agent", localProjects: [project]),
                        ConnectionProfile(id: foreignProfileID, name: "其他连接", serverURL: "https://other.test/v1", model: "agent", localProjects: [foreignProject])]
        let message = ChatMessage(role: .assistant, content: String(repeating: "前", count: 230) + "星河正文 Café 中文🙂 共同标识", createdAt: date,
            bookmark: .init(createdAt: date, note: "仅备注命中的萤火收藏"))
        let current = Conversation(title: "星河主对话", messages: [message], updatedAt: date.addingTimeInterval(3), profileID: profileID,
            projectID: project.id, referenceDocumentIDs: [document.id])
        let otherMessage = ChatMessage(id: message.id, role: .user, content: "共同标识", createdAt: date)
        let other = Conversation(title: "独立来源", messages: [otherMessage], updatedAt: date.addingTimeInterval(2), profileID: profileID)
        let archived = Conversation(title: "星河归档", messages: [.init(role: .assistant, content: "星河归档正文", createdAt: date)], updatedAt: date,
            profileID: profileID, workspace: .init(archived: true), projectID: project.id)
        let trash = Conversation(title: "星河回收站", messages: [.init(role: .assistant, content: "星河回收站正文", createdAt: date)], updatedAt: date,
            profileID: profileID, workspace: .init(trashedAt: date), projectID: project.id)
        let foreign = Conversation(title: "星河跨连接", messages: [.init(role: .assistant, content: "星河跨连接正文", createdAt: date)], updatedAt: date,
            profileID: foreignProfileID, projectID: foreignProject.id)
        let records = empty ? [] : [current, other, archived, trash, foreign]
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("conversations.json"))
        let selections = empty ? [:] : [profileID.uuidString: current.id.uuidString, foreignProfileID.uuidString: foreign.id.uuidString]
        let library = ConnectionLibrary(profiles: profiles, activeID: profileID, selectedConversations: selections)
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"))
        var drafts = empty ? [:] : [DraftStore.localKey(profileID: profileID, conversationID: current.id): "星河当前草稿",
                                    DraftStore.localKey(profileID: profileID, conversationID: other.id): "独立来源草稿",
                                    DraftStore.localKey(profileID: profileID, conversationID: archived.id): "星河归档草稿",
                                    DraftStore.localKey(profileID: profileID, conversationID: trash.id): "星河回收站草稿",
                                    DraftStore.localKey(profileID: profileID, conversationID: nil): "星河新草稿",
                                    DraftStore.localKey(profileID: foreignProfileID, conversationID: foreign.id): "星河跨连接草稿",
                                    "\(profileID.uuidString)/remote/session": "星河远端草稿"]
        if includeOrphans && !empty {
            drafts[DraftStore.localKey(profileID: profileID, conversationID: orphanID)] = "星河孤儿草稿"
            drafts["\(profileID.uuidString)/local/not-a-uuid"] = "星河无效草稿"
        }
        try JSONEncoder().encode(drafts).write(to: directory.appendingPathComponent("drafts.json"))
        let keys = MemoryCredentials()
        keys.values["api-server-key"] = "discovery-fixture-key"
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return DiscoveryFixture(defaults: defaults, directory: directory, keys: keys, profileID: profileID, foreignProfileID: foreignProfileID,
            projectID: project.id, foreignProjectID: foreignProject.id, documentID: document.id, currentID: current.id,
            otherID: other.id, archivedID: archived.id, trashID: trash.id, foreignID: foreign.id, orphanID: orphanID,
            currentTarget: .init(conversationID: current.id, messageID: message.id), otherTarget: .init(conversationID: other.id, messageID: otherMessage.id))
    }
}

private struct DiscoveryFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    let profileID: UUID
    let foreignProfileID: UUID
    let projectID: UUID
    let foreignProjectID: UUID
    let documentID: UUID
    let currentID: UUID
    let otherID: UUID
    let archivedID: UUID
    let trashID: UUID
    let foreignID: UUID
    let orphanID: UUID
    let currentTarget: LocalMessageTarget
    let otherTarget: LocalMessageTarget
    var historyURL: URL { directory.appendingPathComponent("conversations.json") }
    var connectionsURL: URL { directory.appendingPathComponent("connections.json") }
    var draftsURL: URL { directory.appendingPathComponent("drafts.json") }
    func historyData() throws -> Data { try Data(contentsOf: historyURL) }
    func history() throws -> [Conversation] { try JSONDecoder().decode([Conversation].self, from: historyData()) }
    func library() throws -> ConnectionLibrary { try JSONDecoder().decode(ConnectionLibrary.self, from: Data(contentsOf: connectionsURL)) }
    func drafts() throws -> [String: String] { try JSONDecoder().decode([String: String].self, from: Data(contentsOf: draftsURL)) }
    @MainActor func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocol.self]
        return AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: configuration)
    }
}

private final class DiscoveryURLProtocol: URLProtocol {
    static var handler: ((DiscoveryURLProtocol) -> Void)?
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
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"探索测试回复\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
