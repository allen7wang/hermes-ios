import XCTest
import SwiftUI
import UIKit
@testable import Hermes

/// Layout evidence with local fixtures; these checks do not exercise native clicks or file round trips.
final class ProjectDocumentUsageVisualTests: XCTestCase {
    @MainActor func testUsageLibraryCompactLayout() async throws {
        let fixture = try makeFixture()
        let view = NavigationStack {
            ProjectKnowledgeView(projectID: fixture.projectID, profileID: fixture.profileID)
        }.environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 1100), name: "usage-library-compact")
        XCTAssertEqual(fixture.model.projects.first?.documents, fixture.documents)
    }

    @MainActor func testDocumentUsageWideLayout() async throws {
        let fixture = try makeFixture()
        let view = NavigationStack {
            ProjectDocumentUsageView(projectID: fixture.projectID, profileID: fixture.profileID,
                documentID: fixture.documents[0].id)
        }.environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 1024, height: 1100), name: "usage-detail-wide")
        XCTAssertEqual(fixture.model.projectDocumentConversations(projectID: fixture.projectID,
            profileID: fixture.profileID).count, 3)
    }

    @MainActor func testDeletionReviewCompactLayout() async throws {
        let fixture = try makeFixture()
        let review = try fixture.model.reviewProjectDocumentDeletion([fixture.documents[0], fixture.documents[2]],
            projectID: fixture.projectID, profileID: fixture.profileID)
        let view = ProjectDocumentDeletionReviewView(review: review, onDeleted: {})
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 1200), name: "deletion-review-compact")
        XCTAssertEqual(fixture.model.projects.first?.documents, fixture.documents)
        XCTAssertEqual(fixture.model.projectDocumentConversations(projectID: fixture.projectID,
            profileID: fixture.profileID).count, 3)
    }

    @MainActor private func snapshot<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let controller = UIHostingController(rootView: view
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(950))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, size.width, accuracy: 1)
        XCTAssertEqual(image.size.height, size.height, accuracy: 1)
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 1_000)
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v3-3-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func makeFixture() throws -> UsageVisualFixture {
        let suite = "HermesDocumentUsageVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let date = Date(timeIntervalSince1970: 1_792_600_000)
        let profileID = UUID(uuidString: "33000000-0000-0000-0000-000000000001")!
        let projectID = UUID(uuidString: "33000000-0000-0000-0000-000000000101")!
        let documents = [
            ProjectDocument(id: UUID(uuidString: "33000000-0000-0000-0000-000000000301")!,
                title: "产品定位、交付边界与跨版本资料整理的完整约定",
                body: "# Hermes 项目约定\n\n资料保存在当前连接的本机项目中。对话明确选择引用资料，已归档和回收站中的引用也应纳入整理前的检查。\n\n删除资料会移除对话中的对应引用，原始消息仍然保留。",
                createdAt: date, updatedAt: date),
            ProjectDocument(id: UUID(uuidString: "33000000-0000-0000-0000-000000000302")!,
                title: "本周发布验收清单",
                body: "检查资料使用情况、删除影响预览和连接隔离。记录自动测试与尚未完成的原生交互验收。",
                createdAt: date, updatedAt: date.addingTimeInterval(-60)),
            ProjectDocument(id: UUID(uuidString: "33000000-0000-0000-0000-000000000303")!,
                title: "待整理的阅读笔记 · 尚未引用",
                body: "这份资料尚未被任何对话选中。保留在项目资料库，需要时再为对话添加引用。",
                createdAt: date, updatedAt: date.addingTimeInterval(-120))
        ]
        var project = LocalProject(id: projectID, name: "Hermes 资料整理", summary: "看清引用关系，再整理项目资料。",
            instructions: "用中文回答，区分已验证结果与待完成事项。", createdAt: date, updatedAt: date)
        project.documents = documents
        let profile = ConnectionProfile(id: profileID, name: "个人工作空间",
            serverURL: "https://usage-preview.hermes.test", model: "hermes-agent", localProjects: [project])
        let activeID = UUID(uuidString: "33000000-0000-0000-0000-000000000201")!
        let conversations = [
            Conversation(id: activeID, title: "进行中 · 本周发布与资料交付讨论",
                messages: [ChatMessage(role: .user, content: "请结合项目约定和验收清单，整理本周发布计划。", createdAt: date)],
                updatedAt: date, profileID: profileID, workspace: .init(), projectID: projectID,
                referenceDocumentIDs: [documents[1].id, documents[0].id]),
            Conversation(id: UUID(uuidString: "33000000-0000-0000-0000-000000000202")!,
                title: "已归档 · 上一轮产品边界确认",
                messages: [ChatMessage(role: .assistant, content: "已确认项目边界，保留本轮讨论记录。", createdAt: date)],
                updatedAt: date.addingTimeInterval(-60), profileID: profileID, workspace: .init(archived: true),
                projectID: projectID, referenceDocumentIDs: [documents[0].id]),
            Conversation(id: UUID(uuidString: "33000000-0000-0000-0000-000000000203")!,
                title: "回收站 · 早期资料整理草稿",
                messages: [ChatMessage(role: .user, content: "保留原始消息，便于恢复后继续检查引用关系。", createdAt: date)],
                updatedAt: date.addingTimeInterval(-120), profileID: profileID,
                workspace: .init(trashedAt: date.addingTimeInterval(-30)), projectID: projectID,
                referenceDocumentIDs: [documents[0].id])
        ]
        let library = ConnectionLibrary(profiles: [profile], activeID: profileID,
            selectedConversations: [profileID.uuidString: activeID.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        try JSONEncoder().encode(conversations).write(to: directory.appendingPathComponent("conversations.json"), options: .atomic)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageVisualNetworkGuard.self]
        let model = AppModel(defaults: defaults, directory: directory, credentials: MemoryCredentials(),
            sessionConfiguration: configuration)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertFalse(model.settings.isConfigured)
        XCTAssertEqual(model.projects.first?.documents.count, 3)
        XCTAssertEqual(model.projectDocumentConversations(projectID: projectID, profileID: profileID).count, 3)
        return UsageVisualFixture(model: model, profileID: profileID, projectID: projectID, documents: documents)
    }
}

private struct UsageVisualFixture {
    let model: AppModel
    let profileID: UUID
    let projectID: UUID
    let documents: [ProjectDocument]
}

private final class UsageVisualNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("资料使用情况布局检查不应发送网络请求。")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
