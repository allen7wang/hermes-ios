import XCTest
import SwiftUI
import UIKit
@testable import Hermes

/// Rendered in a validation window with isolated example data, not device interaction tests.
final class ProjectDocumentVisualTests: XCTestCase {
    @MainActor func testKnowledgeLibraryCompactLayout() async throws {
        let fixture = try makeFixture()
        let view = NavigationStack {
            ProjectKnowledgeView(projectID: fixture.projectID, profileID: fixture.model.activeProfileID)
        }.environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 844), name: "knowledge-compact")
    }

    @MainActor func testReferenceSelectionWideLayout() async throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.model.currentReferenceDocuments.count, 2)
        let view = ProjectDocumentSelectionView(conversationID: fixture.conversationID, profileID: fixture.model.activeProfileID)
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 1024, height: 1000), name: "reference-selection-wide")
    }

    @MainActor func testReferenceContextPreviewCompactLayout() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.draft = "结合已选资料，整理这次发布的计划，并标注资料出处。"
        let preview = try model.previewNextRequest(model.draft, hasImage: false, expectedDraftKey: model.draftKey)
        XCTAssertEqual(preview.plan.referenceDocuments.map(\.title), ["产品定位与边界", "发布验收约定"])
        XCTAssertFalse(preview.plan.effectiveSystemPrompt.contains("未选中的阅读笔记正文"))
        try await snapshot(ChatContextPreviewView(preview: preview).environmentObject(model),
            size: CGSize(width: 390, height: 844), name: "reference-context-compact")
    }

    @MainActor private func snapshot<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let controller = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "zh_CN")).preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(900))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, size.width, accuracy: 1)
        XCTAssertEqual(image.size.height, size.height, accuracy: 1)
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 1_000)
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v3-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func makeFixture() throws -> DocumentVisualFixture {
        let suite = "HermesDocumentVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_792_713_600)
        let profileID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let projectID = UUID(uuidString: "30000000-0000-0000-0000-000000000101")!
        let conversationID = UUID(uuidString: "30000000-0000-0000-0000-000000000201")!
        let documents = [
            ProjectDocument(id: UUID(uuidString: "30000000-0000-0000-0000-000000000301")!, title: "产品定位与边界",
                body: "# Hermes 3.0\n\n为长期项目整理对话和参考资料。\n\n- 资料保存在当前连接的本机项目中\n- 每段对话明确选择要携带的资料\n- 完整正文随请求发送，标明引用出处",
                createdAt: date, updatedAt: date),
            ProjectDocument(id: UUID(uuidString: "30000000-0000-0000-0000-000000000302")!, title: "发布验收约定",
                body: "发布前检查项目资料保存、引用顺序、备份恢复与连接隔离。\n\n清楚记录已通过的测试，以及尚未完成的真机和服务端验收。",
                createdAt: date, updatedAt: date.addingTimeInterval(-60)),
            ProjectDocument(id: UUID(uuidString: "30000000-0000-0000-0000-000000000303")!, title: "阅读笔记 · 尚未选择",
                body: "未选中的阅读笔记正文。先保存在资料库，等需要时再为对话添加引用。",
                createdAt: date, updatedAt: date.addingTimeInterval(-120))
        ]
        var project = LocalProject(id: projectID, name: "Hermes 3.0 发布", summary: "整理资料，让讨论有据可循。",
            instructions: "用中文回答，区分已验证结果与待完成事项。", createdAt: date, updatedAt: date)
        project.documents = documents
        let profile = ConnectionProfile(id: profileID, name: "个人工作空间", serverURL: "https://document-preview.hermes.test",
            model: "hermes-agent", localProjects: [project])
        let library = ConnectionLibrary(profiles: [profile], activeID: profileID, selectedConversations: [profileID.uuidString: conversationID.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        var conversation = Conversation(id: conversationID, title: "把资料变成发布计划", messages: [
            ChatMessage(role: .user, content: "我们先确认这次发布的目标和边界。", createdAt: date),
            ChatMessage(role: .assistant, content: "可以先选中产品定位和验收约定，再整理行动清单。", createdAt: date)
        ], updatedAt: date, profileID: profileID, workspace: .init(configuration: .init(contextTurns: 6)), projectID: projectID)
        conversation.referenceDocumentIDs = Array(documents.prefix(2)).map(\.id)
        try JSONEncoder().encode([conversation]).write(to: directory.appendingPathComponent("conversations.json"), options: .atomic)
        let keys = MemoryCredentials(); keys.values[profile.credentialAccount] = "document-layout-fixture-only"
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DocumentVisualNetworkGuard.self]
        let model = AppModel(defaults: defaults, directory: directory, credentials: keys, sessionConfiguration: configuration)
        XCTAssertFalse(model.needsRecovery); XCTAssertEqual(model.projects.first?.documents.count, 3)
        return DocumentVisualFixture(model: model, projectID: projectID, conversationID: conversationID)
    }
}

private struct DocumentVisualFixture {
    let model: AppModel
    let projectID: UUID
    let conversationID: UUID
}

private final class DocumentVisualNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("项目资料布局检查不应发送网络请求。")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
