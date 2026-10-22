import XCTest
import SwiftUI
import UIKit
@testable import Hermes

final class ProjectDocumentBatchTests: XCTestCase {
    func testBatchSelectionAllowsTwentyDocumentsAndRejectsMissingOrEmpty() throws {
        let docs = (0..<20).map { ProjectDocument(title: "资料\($0)", body: "正文") }
        let project = LocalProject(name: "项目", summary: "", instructions: "", knowledgeDocuments: docs)
        XCTAssertEqual(try ProjectDocumentBatch.selected(Set(docs.map(\.id)), in: project).count, 20)
        XCTAssertThrowsError(try ProjectDocumentBatch.selected([], in: project))
        XCTAssertThrowsError(try ProjectDocumentBatch.selected([UUID()], in: project))
        XCTAssertThrowsError(try ProjectDocumentBatch.validate([docs[0], docs[0]], in: project))
    }

    func testMarkdownKeepsReviewedOrderAndCompleteBodiesWithoutUnselectedContent() throws {
        let docs = [ProjectDocument(title: "第二篇", body: String(repeating: "完整正文", count: 5000)),
            ProjectDocument(title: "第一篇", body: "# 原始标题\n\n```swift\nlet value = 1\n```\n\n结束标记")]
        let text = try ProjectDocumentBatch.markdown(projectName: "发布资料", documents: docs)
        XCTAssertTrue(text.hasPrefix("# 发布资料 · 资料汇编"))
        XCTAssertTrue(text.contains("共 2 篇资料"))
        for doc in docs { XCTAssertTrue(text.contains(doc.body)) }
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "## 1. 第二篇")?.lowerBound), try XCTUnwrap(text.range(of: "## 2. 第一篇")?.lowerBound))
        XCTAssertThrowsError(try ProjectDocumentBatch.markdown(projectName: "空", documents: []))
    }

    @MainActor func testCopyCreatesIndependentPersistedDocumentsAndKeepsOriginalState() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); model.draft = "保留我的草稿"
        let docs = try source(model, f).documents; let before = try model.makeBackup()
        let ids = try model.copyProjectDocuments(Array(docs.prefix(2)), fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID)
        let copied = try target(f.model(), f).documents
        XCTAssertEqual(copied.map(\.id), ids); XCTAssertEqual(copied.map(\.body), Array(docs.prefix(2)).map(\.body))
        XCTAssertTrue(Set(ids).isDisjoint(with: docs.map(\.id))); XCTAssertTrue(copied.allSatisfy { $0.createdAt > docs[0].createdAt })
        XCTAssertEqual(try source(model, f).documents, docs)
        XCTAssertEqual(try model.makeBackup().conversations, before.conversations)
        XCTAssertEqual(try model.makeBackup().drafts, before.drafts); XCTAssertEqual(model.draft, "保留我的草稿")
        _ = try model.saveProjectDocument(id: ids[0], projectID: f.targetID, title: "独立修改", body: "只改副本", profileID: f.profileID)
        XCTAssertEqual(try source(model, f).documents, docs)
    }

    @MainActor func testCopyPreservesSameTitlesAsIndependentNewRecords() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); let doc = try source(model, f).documents[0]
        for _ in 0..<2 { try model.copyProjectDocuments([doc], fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID) }
        let copied = try target(model, f).documents
        XCTAssertEqual(copied.map(\.title), [doc.title, doc.title]); XCTAssertEqual(Set(copied.map(\.id)).count, 2)
    }

    @MainActor func testCopyRejectsChangedSelectedSnapshotButAllowsUnrelatedEdits() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); let docs = try source(model, f).documents
        _ = try model.saveProjectDocument(id: docs[2].id, projectID: f.sourceID, title: "未选资料更新", body: "新内容", profileID: f.profileID)
        XCTAssertNoThrow(try model.copyProjectDocuments([docs[0]], fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID))
        _ = try model.saveProjectDocument(id: docs[0].id, projectID: f.sourceID, title: "所选资料更新", body: "新版本", profileID: f.profileID)
        let before = model.profiles
        XCTAssertThrowsError(try model.copyProjectDocuments(Array(docs.prefix(2)), fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID))
        XCTAssertEqual(model.profiles, before)
    }

    @MainActor func testCopyRejectsSameMissingForeignAndEmptyTargets() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); let docs = try source(model, f).documents
        XCTAssertThrowsError(try model.copyProjectDocuments(docs, fromProject: f.sourceID, toProject: f.sourceID, profileID: f.profileID))
        XCTAssertThrowsError(try model.copyProjectDocuments(docs, fromProject: f.sourceID, toProject: UUID(), profileID: f.profileID))
        XCTAssertThrowsError(try model.copyProjectDocuments([], fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID))
        XCTAssertThrowsError(try model.copyProjectDocuments(docs, fromProject: f.sourceID, toProject: f.targetID, profileID: UUID()))
        XCTAssertTrue(try target(model, f).documents.isEmpty)
    }

    @MainActor func testCopyRechecksLatestTargetCountAndDoesNotPartiallyCopy() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); let docs = try source(model, f).documents
        for index in 0..<19 { _ = try model.saveProjectDocument(id: nil, projectID: f.targetID, title: "已有\(index)", body: "内容", profileID: f.profileID) }
        let before = model.profiles
        XCTAssertThrowsError(try model.copyProjectDocuments(Array(docs.prefix(2)), fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID))
        XCTAssertEqual(model.profiles, before); XCTAssertEqual(try target(f.model(), f).documents.count, 19)
        XCTAssertEqual(try model.copyProjectDocuments([docs[0]], fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID).count, 1)
        XCTAssertEqual(try target(f.model(), f).documents.count, 20)
    }

    @MainActor func testCopyRechecksTargetCharacterBudgetWithoutPartialWrites() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); let docs = try source(model, f).documents
        for index in 0..<10 { _ = try model.saveProjectDocument(id: nil, projectID: f.targetID, title: "完整资料\(index)", body: String(repeating: "字", count: 20_000), profileID: f.profileID) }
        let before = model.profiles
        XCTAssertThrowsError(try model.copyProjectDocuments([docs[0]], fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID))
        XCTAssertEqual(model.profiles, before); XCTAssertEqual(try target(f.model(), f).documents.count, 10)
        let boundary = LocalProject(name: "边界", summary: "", instructions: "", knowledgeDocuments: (0..<10).map { ProjectDocument(title: "\($0)", body: String(repeating: "字", count: 19_999)) })
        XCTAssertNoThrow(try ProjectDocumentBatch.validateCapacity([.init(title: "补齐", body: "0123456789")], target: boundary))
        XCTAssertThrowsError(try ProjectDocumentBatch.validateCapacity([.init(title: "超出", body: "01234567890")], target: boundary))
    }

    @MainActor func testCopyWriteFailureKeepsPublishedAndPersistedSource() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); let docs = try source(model, f).documents
        let before = model.profiles; let url = f.directory.appendingPathComponent("connections.json")
        let original = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.copyProjectDocuments(docs, fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID))
        XCTAssertEqual(model.profiles, before); XCTAssertFalse(model.needsRecovery)
        try FileManager.default.removeItem(at: url); try original.write(to: url)
        XCTAssertTrue(try target(f.model(), f).documents.isEmpty)
    }

    @MainActor func testBulkDeleteClearsEveryConversationAndKeepsRemainingReferenceOrderAndDrafts() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); model.draft = "保留草稿"
        let docs = try source(model, f).documents; let before = try model.makeBackup()
        try model.deleteProjectDocuments([docs[0], docs[2]], projectID: f.sourceID, profileID: f.profileID)
        let after = try model.makeBackup()
        XCTAssertEqual(try source(model, f).documents, [docs[1]])
        XCTAssertTrue(after.conversations.allSatisfy { $0.referenceDocumentIDs == [docs[1].id] })
        XCTAssertEqual(after.conversations.map(\.messages), before.conversations.map(\.messages))
        XCTAssertEqual(after.conversations.map(\.workspace), before.conversations.map(\.workspace))
        XCTAssertEqual(after.conversations.map(\.updatedAt), before.conversations.map(\.updatedAt))
        XCTAssertEqual(after.drafts, before.drafts); XCTAssertEqual(after.images, before.images)
        XCTAssertEqual(model.draft, "保留草稿"); XCTAssertFalse(f.model().needsRecovery)
    }

    @MainActor func testBulkDeleteRejectsStaleSnapshotOrAnyMissingItemBeforeDeletingAnything() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); let docs = try source(model, f).documents
        _ = try model.saveProjectDocument(id: docs[0].id, projectID: f.sourceID, title: "最新标题", body: "不能被旧确认删除", profileID: f.profileID)
        let before = try model.makeBackup()
        XCTAssertThrowsError(try model.deleteProjectDocuments(docs, projectID: f.sourceID, profileID: f.profileID))
        XCTAssertThrowsError(try model.deleteProjectDocuments([docs[1], .init(title: "失联", body: "失联")], projectID: f.sourceID, profileID: f.profileID))
        XCTAssertEqual(try model.makeBackup().profiles, before.profiles)
        XCTAssertEqual(try model.makeBackup().conversations, before.conversations)
    }

    @MainActor func testBulkDeleteInterruptedTransactionRecoversAllDocumentsAndReferencesTogether() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); let docs = try source(model, f).documents
        let url = f.directory.appendingPathComponent("drafts.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.deleteProjectDocuments(Array(docs.prefix(2)), projectID: f.sourceID, profileID: f.profileID))
        XCTAssertTrue(model.needsRecovery); XCTAssertEqual(try source(model, f).documents, docs)
        XCTAssertThrowsError(try model.copyProjectDocuments([docs[2]], fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID))
        try FileManager.default.removeItem(at: url)
        let reopened = f.model(); XCTAssertFalse(reopened.needsRecovery)
        XCTAssertEqual(try source(reopened, f).documents, [docs[2]])
        XCTAssertTrue(try reopened.makeBackup().conversations.allSatisfy { $0.referenceDocumentIDs == [docs[2].id] })
    }

    @MainActor func testCopiedKnowledgeRemainsInVersionSevenBackupAndForeignRoundTrip() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); let docs = try source(model, f).documents
        try model.copyProjectDocuments([docs[1], docs[0]], fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID)
        let archive = try BackupArchive.decode(model.makeBackup().encoded()); XCTAssertEqual(archive.version, 7)
        let empty = ConnectionProfile(name: "空连接", serverURL: "", model: "hermes-agent")
        let merge = try BackupMerge.prepare(archive, installationID: UUID(), library: .init(profiles: [empty], activeID: empty.id), conversations: [], drafts: [:])
        XCTAssertEqual(merge.report.documentsAdded, 5)
        let copied = try XCTUnwrap(merge.state.library.profiles.flatMap(\.projects).first { $0.name == "产品发布" })
        XCTAssertEqual(copied.documents.map(\.body), [docs[1].body, docs[0].body])
        XCTAssertEqual(Set(copied.documents.map(\.id)).count, 2)
    }

    @MainActor func testBulkDeleteRejectsEmptyAndStaleProfileAndCopiedProjectRemainsIndependent() throws {
        let f = try BatchFixture.make(owner: self); let model = f.model(); let docs = try source(model, f).documents
        try model.copyProjectDocuments(docs, fromProject: f.sourceID, toProject: f.targetID, profileID: f.profileID)
        XCTAssertThrowsError(try model.deleteProjectDocuments([], projectID: f.sourceID, profileID: f.profileID))
        XCTAssertThrowsError(try model.deleteProjectDocuments(docs, projectID: f.sourceID, profileID: UUID()))
        try model.deleteProjectDocuments(docs, projectID: f.sourceID, profileID: f.profileID)
        XCTAssertTrue(try source(model, f).documents.isEmpty)
        XCTAssertEqual(try target(model, f).documents.map(\.body), docs.map(\.body))
        XCTAssertTrue(try model.makeBackup().conversations.allSatisfy { ($0.referenceDocumentIDs ?? []).isEmpty })
    }

    @MainActor func testBatchCompactLayout() async throws {
        let f = try BatchFixture.make(owner: self)
        try await snapshot(ProjectDocumentBatchView(projectID: f.sourceID, profileID: f.profileID).environmentObject(f.model()), size: .init(width: 390, height: 1000), name: "batch-compact")
    }
    @MainActor func testCopyReviewWideLayout() async throws {
        let f = try BatchFixture.make(owner: self); let model = f.model()
        try await snapshot(ProjectDocumentCopyView(projectID: f.sourceID, profileID: f.profileID, documents: try source(model, f).documents, onCopied: { _, _ in }).environmentObject(model), size: .init(width: 1024, height: 1000), name: "copy-wide")
    }
    @MainActor func testExportReviewCompactLayout() async throws {
        let f = try BatchFixture.make(owner: self); let model = f.model()
        try await snapshot(ProjectDocumentExportView(projectName: "调研资料", documents: Array(try source(model, f).documents.prefix(2))), size: .init(width: 390, height: 1000), name: "export-compact")
    }

    @MainActor private func source(_ model: AppModel, _ f: BatchFixture) throws -> LocalProject { try XCTUnwrap(model.projects.first { $0.id == f.sourceID }) }
    @MainActor private func target(_ model: AppModel, _ f: BatchFixture) throws -> LocalProject { try XCTUnwrap(model.projects.first { $0.id == f.targetID }) }
    @MainActor private func snapshot<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let controller = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "zh_CN")).preferredColorScheme(.dark))
        let window = UIWindow(frame: .init(origin: .zero, size: size)); window.rootViewController = controller
        window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible(); defer { window.isHidden = true }
        controller.view.frame = .init(origin: .zero, size: size); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(950)); controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
        let data = try XCTUnwrap(image.pngData()); XCTAssertGreaterThan(data.count, 1000)
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v3-2-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

@MainActor private struct BatchFixture {
    let defaults: UserDefaults
    let directory: URL
    let profileID: UUID
    let sourceID: UUID
    let targetID: UUID
    static func make(owner: XCTestCase) throws -> Self {
        let suite = "HermesDocumentBatch.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1792600000)
        let docs = [ProjectDocument(title: "用户访谈摘要", body: "# 调研结论\n\n- 长期项目需要复用资料\n- 分享前检查完整内容", createdAt: date, updatedAt: date),
            ProjectDocument(title: "发布验收约定", body: "确认资料复制独立、容量检查及批量删除恢复。", createdAt: date, updatedAt: date.addingTimeInterval(-60)),
            ProjectDocument(title: "待整理的参考笔记", body: "这份资料暂时留在来源项目。", createdAt: date, updatedAt: date.addingTimeInterval(-120))]
        let source = LocalProject(name: "调研资料", summary: "整理访谈与阅读结果", instructions: "区分事实与假设", createdAt: date, updatedAt: date, knowledgeDocuments: docs)
        let target = LocalProject(name: "产品发布", summary: "复用已检查的背景资料", instructions: "清楚列出行动项", createdAt: date, updatedAt: date.addingTimeInterval(-60))
        let profile = ConnectionProfile(name: "个人工作空间", serverURL: "https://document-batch.hermes.test", model: "hermes-agent", localProjects: [source, target])
        let records = (0..<3).map { index in
            Conversation(title: "参考讨论\(index)", messages: [.init(role: .user, content: "保留原始问题", createdAt: date), .init(role: .assistant, content: "保留回复与收藏", createdAt: date, bookmark: .init(createdAt: date, note: "私有备注"))], updatedAt: date, profileID: profile.id, workspace: .init(archived: index == 1, trashedAt: index == 2 ? date : nil), projectID: source.id, referenceDocumentIDs: [docs[2].id, docs[0].id, docs[1].id])
        }
        let library = ConnectionLibrary(profiles: [profile], activeID: profile.id, selectedConversations: [profile.id.uuidString: records[0].id.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"))
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("conversations.json"))
        owner.addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return Self(defaults: defaults, directory: directory, profileID: profile.id, sourceID: source.id, targetID: target.id)
    }
    func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [BatchNetworkGuard.self]
        return AppModel(defaults: defaults, directory: directory, credentials: MemoryCredentials(), sessionConfiguration: configuration)
    }
}
private final class BatchNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { XCTFail("批量资料检查不应联网"); client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
