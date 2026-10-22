import XCTest
import SwiftUI
import UIKit
@testable import Hermes

final class KnowledgeIterationTests: XCTestCase {
    @MainActor func testCaptureIsReadOnlyAndKeepsSourceAndComposerIndependent() throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        model.draft = "当前独立草稿"
        let before = try model.makeBackup()
        let capture = try model.captureProjectDocument(f.target, profileID: f.profileID)
        let after = try model.makeBackup()
        XCTAssertEqual(capture.projectID, f.projectID)
        XCTAssertTrue(capture.document.body.contains("来源：发布方案 · Hermes"))
        XCTAssertTrue(capture.document.body.contains("先核对引用顺序，再整理验收记录。"))
        XCTAssertFalse(capture.document.body.contains("私有收藏备注"))
        XCTAssertEqual(before.profiles, after.profiles); XCTAssertEqual(before.conversations, after.conversations)
        XCTAssertEqual(before.drafts, after.drafts); XCTAssertEqual(model.draft, "当前独立草稿")
    }

    @MainActor func testCaptureUsesSourceProjectEvenWhenAnotherConversationIsSelected() throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        let other = try model.startProjectConversation(f.otherProjectID, profileID: f.profileID)
        model.draft = "另一个项目的草稿"
        let capture = try model.captureProjectDocument(f.target, profileID: f.profileID)
        XCTAssertEqual(capture.projectID, f.projectID)
        XCTAssertEqual(model.selectedID, other); XCTAssertEqual(model.draft, "另一个项目的草稿")
        XCTAssertTrue(model.currentReferenceDocuments.isEmpty)
    }

    func testCaptureKeepsLongBodyForExplicitEditingWithoutSilentTruncation() throws {
        let text = String(repeating: "字", count: 20_001)
        let message = ChatMessage(role: .assistant, content: text)
        let conversation = Conversation(title: "长回复", messages: [message], updatedAt: Date(), projectID: UUID())
        let capture = try ProjectDocumentCapture(message: message, conversation: conversation, profileID: UUID())
        XCTAssertTrue(capture.document.body.hasSuffix(text))
        XCTAssertThrowsError(try capture.document.validated())
    }

    func testCaptureRejectsEmptyImageOnlyAndExcessiveMessages() throws {
        let conversation = Conversation(title: "文字", messages: [], updatedAt: Date(), projectID: UUID())
        XCTAssertThrowsError(try ProjectDocumentCapture(message: .init(role: .user, content: " \n", imageID: UUID()), conversation: conversation, profileID: UUID()))
        XCTAssertThrowsError(try ProjectDocumentCapture(message: .init(role: .assistant, content: String(repeating: "x", count: 100_001)), conversation: conversation, profileID: UUID()))
    }

    func testCaptureMarksImageOmissionAndDoesNotCopyBookmarkOrImageIdentifier() throws {
        let imageID = UUID()
        let message = ChatMessage(role: .user, content: "请解释这张图", imageID: imageID, bookmark: .init(createdAt: Date(), note: "不应采集的备注"))
        let conversation = Conversation(title: "图文问题", messages: [message], updatedAt: Date(), projectID: UUID())
        let capture = try ProjectDocumentCapture(message: message, conversation: conversation, profileID: UUID())
        XCTAssertTrue(capture.document.body.contains("图片未包含")); XCTAssertTrue(capture.document.body.contains("请解释这张图"))
        XCTAssertFalse(capture.document.body.contains(imageID.uuidString)); XCTAssertFalse(capture.document.body.contains("不应采集的备注"))
    }

    @MainActor func testCaptureRejectsMissingMessageUnassignedTrashAndStaleProfile() throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        XCTAssertThrowsError(try model.captureProjectDocument(.init(conversationID: f.conversationID, messageID: UUID()), profileID: f.profileID))
        XCTAssertThrowsError(try model.captureProjectDocument(f.target, profileID: UUID()))
        try model.assignConversations([f.conversationID], toProject: nil, profileID: f.profileID)
        XCTAssertThrowsError(try model.captureProjectDocument(f.target, profileID: f.profileID))
        try model.assignConversations([f.conversationID], toProject: f.projectID, profileID: f.profileID)
        try model.deleteConversations([f.conversationID])
        XCTAssertThrowsError(try model.captureProjectDocument(f.target, profileID: f.profileID))
    }

    @MainActor func testArchivedCaptureAndReviewedSaveDoNotSelectOrSendKnowledge() throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        try model.setArchived([f.conversationID], archived: true)
        let capture = try model.captureProjectDocument(f.target, profileID: f.profileID)
        let beforeIDs = model.selectedConversation?.referenceDocumentIDs
        let id = try model.saveProjectDocument(id: nil, projectID: capture.projectID, title: capture.document.title,
            body: capture.document.body, profileID: f.profileID)
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, beforeIDs)
        XCTAssertTrue(model.projects.first { $0.id == f.projectID }!.documents.contains { $0.id == id })
        XCTAssertEqual(model.selectedConversation?.messages.count, 2)
        XCTAssertEqual(try model.makeBackup().version, 7)
    }

    @MainActor func testStaleDocumentSnapshotCannotOverwriteLatestPersistedEdit() throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        let old = try XCTUnwrap(model.projects.first?.documents.first)
        _ = try model.saveProjectDocument(id: old.id, projectID: f.projectID, title: "已保存的新标题", body: "另一个窗口的新正文", profileID: f.profileID, expectedDocument: old)
        XCTAssertThrowsError(try model.saveProjectDocument(id: old.id, projectID: f.projectID, title: "过期输入", body: "不能覆盖", profileID: f.profileID, expectedDocument: old)) { error in
            guard case ProjectDocumentError.changedDocument = error else { return XCTFail("Expected document conflict") }
        }
        XCTAssertEqual(f.model().projects.first?.documents.first?.body, "另一个窗口的新正文")
    }

    @MainActor func testReloadedDocumentSnapshotCanSaveAgainWithoutLosingCreatedDate() throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        let first = try XCTUnwrap(model.projects.first?.documents.first)
        _ = try model.saveProjectDocument(id: first.id, projectID: f.projectID, title: "第一次修改", body: "正文一", profileID: f.profileID, expectedDocument: first)
        let latest = try XCTUnwrap(model.projects.first?.documents.first)
        _ = try model.saveProjectDocument(id: first.id, projectID: f.projectID, title: "重新载入后", body: "正文二", profileID: f.profileID, expectedDocument: latest)
        XCTAssertEqual(model.projects.first?.documents.first?.createdAt, first.createdAt)
        XCTAssertEqual(model.projects.first?.documents.first?.body, "正文二")
    }

    @MainActor func testStaleEmptyReferenceSnapshotIsCheckedBeforeReplacingNewSelection() throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        try model.selectProjectDocuments([], conversationID: f.conversationID, profileID: f.profileID)
        try model.selectProjectDocuments([f.documentIDs[1]], conversationID: f.conversationID, profileID: f.profileID)
        XCTAssertThrowsError(try model.selectProjectDocuments([f.documentIDs[0]], conversationID: f.conversationID,
            profileID: f.profileID, expectedSelection: [], expectedProjectID: f.projectID))
        XCTAssertEqual(f.model().selectedConversation?.referenceDocumentIDs, [f.documentIDs[1]])
    }

    @MainActor func testReferenceReorderChangesPreviewAndBackupOrderWithoutChangingMessages() throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        let original = try XCTUnwrap(model.selectedConversation)
        let order = Array(f.documentIDs.reversed())
        try model.selectProjectDocuments(order, conversationID: f.conversationID, profileID: f.profileID,
            expectedSelection: f.documentIDs, expectedProjectID: f.projectID)
        let plan = try model.previewNextRequest("生成摘要", hasImage: false, expectedDraftKey: model.draftKey).plan
        XCTAssertEqual(plan.referenceDocuments.map(\.id), order)
        XCTAssertTrue(plan.effectiveSystemPrompt.contains("[资料1] 复盘与验收"))
        XCTAssertEqual(model.selectedConversation?.messages, original.messages)
        let archive = try BackupArchive.decode(model.makeBackup().encoded())
        XCTAssertEqual(archive.conversations.first { $0.id == f.conversationID }?.referenceDocumentIDs, order)
        XCTAssertEqual(archive.version, 7)
    }

    @MainActor func testExpectedProjectRejectsStaleSelectionEvenWhenIDsAreValid() throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        XCTAssertThrowsError(try model.selectProjectDocuments(f.documentIDs, conversationID: f.conversationID,
            profileID: f.profileID, expectedSelection: f.documentIDs, expectedProjectID: f.otherProjectID))
        XCTAssertEqual(model.selectedConversation?.referenceDocumentIDs, f.documentIDs)
    }

    @MainActor func testCaptureEditorCompactLayout() async throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        let capture = try model.captureProjectDocument(f.target, profileID: f.profileID)
        try await snapshot(ProjectDocumentCaptureView(capture: capture).environmentObject(model), size: .init(width: 390, height: 844), name: "capture-compact")
    }

    @MainActor func testReferenceOrderWideLayout() async throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        try await snapshot(ProjectDocumentSelectionView(conversationID: f.conversationID, profileID: f.profileID).environmentObject(model), size: .init(width: 1024, height: 1100), name: "reference-order-wide")
    }

    @MainActor func testConflictingEditorRetainsOriginalInputLayout() async throws {
        let f = try KnowledgeIterationFixture.make(owner: self); let model = f.model()
        let original = try XCTUnwrap(model.projects.first?.documents.first)
        _ = try model.saveProjectDocument(id: original.id, projectID: f.projectID, title: "其他窗口已保存", body: "最新正文", profileID: f.profileID)
        try await snapshot(ProjectDocumentEditorView(projectID: f.projectID, profileID: f.profileID, document: original, onSaved: {}).environmentObject(model), size: .init(width: 390, height: 1200), name: "edit-conflict-compact")
    }

    @MainActor private func snapshot<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let controller = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "zh_CN")).preferredColorScheme(.dark))
        let window = UIWindow(frame: .init(origin: .zero, size: size)); window.rootViewController = controller
        window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible(); defer { window.isHidden = true }
        controller.view.frame = .init(origin: .zero, size: size); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(950)); controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
        let data = try XCTUnwrap(image.pngData()); XCTAssertGreaterThan(data.count, 1000)
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v3-1-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

@MainActor private struct KnowledgeIterationFixture {
    let defaults: UserDefaults
    let directory: URL
    let credentials: MemoryCredentials
    let profileID: UUID
    let projectID: UUID
    let otherProjectID: UUID
    let conversationID: UUID
    let target: LocalMessageTarget
    let documentIDs: [UUID]

    static func make(owner: XCTestCase) throws -> Self {
        let suite = "HermesKnowledgeIteration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1792600000)
        let documents = [ProjectDocument(title: "产品定位与边界", body: "保持用户可控的引用，清楚说明验证范围。", createdAt: date, updatedAt: date),
            ProjectDocument(title: "复盘与验收", body: "检查资料采集、引用顺序与保存冲突。", createdAt: date, updatedAt: date)]
        let project = LocalProject(name: "Hermes 迭代", summary: "资料与对话持续积累", instructions: "区分事实和待验证项。", createdAt: date, updatedAt: date, knowledgeDocuments: documents)
        let other = LocalProject(name: "另一项目", summary: "独立的资料库", instructions: "", createdAt: date.addingTimeInterval(-60), updatedAt: date.addingTimeInterval(-60))
        let profile = ConnectionProfile(name: "个人工作空间", serverURL: "https://knowledge-iteration.hermes.test", model: "hermes-agent", localProjects: [project, other])
        let message = ChatMessage(role: .assistant, content: "## 本次迭代\n\n先核对引用顺序，再整理验收记录。\n\n- 保留原对话与草稿\n- 确认资料内容后保存\n- 记录真实 API 与真机验收范围", createdAt: date, bookmark: .init(createdAt: date, note: "私有收藏备注"))
        let conversation = Conversation(title: "发布方案", messages: [.init(role: .user, content: "把发布建议整理成可复用的资料。", createdAt: date), message], updatedAt: date, profileID: profile.id,
            projectID: project.id, referenceDocumentIDs: documents.map(\.id))
        let library = ConnectionLibrary(profiles: [profile], activeID: profile.id, selectedConversations: [profile.id.uuidString: conversation.id.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"))
        try JSONEncoder().encode([conversation]).write(to: directory.appendingPathComponent("conversations.json"))
        let credentials = MemoryCredentials(); credentials.values[profile.credentialAccount] = "knowledge-iteration-fixture-only"
        owner.addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return Self(defaults: defaults, directory: directory, credentials: credentials, profileID: profile.id, projectID: project.id,
            otherProjectID: other.id, conversationID: conversation.id, target: .init(conversationID: conversation.id, messageID: message.id), documentIDs: documents.map(\.id))
    }
    func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [KnowledgeIterationNetworkGuard.self]
        return AppModel(defaults: defaults, directory: directory, credentials: credentials, sessionConfiguration: configuration)
    }
}
private final class KnowledgeIterationNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { XCTFail("资料采集与编辑测试不应联网"); client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
