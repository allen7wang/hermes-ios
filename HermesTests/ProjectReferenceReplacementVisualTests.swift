import XCTest
import SwiftUI
import UIKit
@testable import Hermes

/// Local layout evidence only; these snapshots do not exercise native clicks or confirm a replacement.
final class ProjectReferenceReplacementVisualTests: XCTestCase {
    @MainActor func testReplacementSelectionCompactLayout() async throws {
        let fixture = try makeFixture()
        let before = fixture.model.projectDocumentConversations(projectID: fixture.projectID, profileID: fixture.profileID)
        let view = ProjectReferenceReplacementView(projectID: fixture.projectID, profileID: fixture.profileID,
            sourceID: fixture.documents[0].id)
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 1100), name: "replacement-select-compact")
        assertUnchanged(fixture, conversations: before)
    }

    @MainActor func testReplacementReviewWideLayout() async throws {
        let fixture = try makeFixture()
        let before = fixture.model.projectDocumentConversations(projectID: fixture.projectID, profileID: fixture.profileID)
        let review = try fixture.model.previewProjectReferenceReplacement(sourceID: fixture.documents[0].id,
            targetID: fixture.documents[1].id, conversationIDs: fixture.conversationIDs,
            projectID: fixture.projectID, profileID: fixture.profileID)
        let view = ProjectReferenceReplacementReviewView(review: review, onApplied: {})
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 1024, height: 1200), name: "replacement-review-wide")
        assertUnchanged(fixture, conversations: before)
    }

    @MainActor func testReplacementReviewCompactLayout() async throws {
        let fixture = try makeFixture()
        let before = fixture.model.projectDocumentConversations(projectID: fixture.projectID, profileID: fixture.profileID)
        let review = try fixture.model.previewProjectReferenceReplacement(sourceID: fixture.documents[0].id,
            targetID: fixture.documents[1].id, conversationIDs: fixture.conversationIDs,
            projectID: fixture.projectID, profileID: fixture.profileID)
        let view = ProjectReferenceReplacementReviewView(review: review, onApplied: {})
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 1300), name: "replacement-review-compact")
        assertUnchanged(fixture, conversations: before)
    }

    @MainActor private func assertUnchanged(_ fixture: ReplacementVisualFixture, conversations: [Conversation],
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.model.projects.first?.documents, fixture.documents, file: file, line: line)
        XCTAssertEqual(fixture.model.projectDocumentConversations(projectID: fixture.projectID,
            profileID: fixture.profileID), conversations, file: file, line: line)
        XCTAssertEqual(conversations.count, 3, file: file, line: line)
        XCTAssertEqual(conversations.filter(\.isArchived).count, 1, file: file, line: line)
        XCTAssertEqual(conversations.filter(\.isTrashed).count, 1, file: file, line: line)
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
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v3-4-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func makeFixture() throws -> ReplacementVisualFixture {
        let suite = "HermesReferenceReplacementVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let date = Date(timeIntervalSince1970: 1_792_600_000)
        let profileID = UUID(uuidString: "34000000-0000-0000-0000-000000000001")!
        let projectID = UUID(uuidString: "34000000-0000-0000-0000-000000000101")!
        let documents = [
            ProjectDocument(id: UUID(uuidString: "34000000-0000-0000-0000-000000000301")!,
                title: "项目交付约定 · 旧版产品定位与跨版本资料整理说明",
                body: "# 旧版交付约定\n\n保留旧资料作为历史记录。需要更新对话的参考资料时，先检查替换后的引用顺序，再明确确认。",
                createdAt: date, updatedAt: date),
            ProjectDocument(id: UUID(uuidString: "34000000-0000-0000-0000-000000000302")!,
                title: "项目交付约定 · 新版产品定位、验收边界与资料引用说明",
                body: "# 新版交付约定\n\n结合当前项目资料制定计划。替换仅更新所选对话保存的引用，保留旧资料和已有消息。\n\n已经引用新版资料的对话需要去重，并保留其他资料的相对顺序。",
                createdAt: date, updatedAt: date.addingTimeInterval(-60)),
            ProjectDocument(id: UUID(uuidString: "34000000-0000-0000-0000-000000000303")!,
                title: "发布验收清单 · 自动测试与交付记录",
                body: "记录自动测试结果、Release 编译状态及尚未完成的原生交互和真机验收。",
                createdAt: date, updatedAt: date.addingTimeInterval(-120)),
            ProjectDocument(id: UUID(uuidString: "34000000-0000-0000-0000-000000000304")!,
                title: "访谈笔记 · 本次不参与替换",
                body: "独立保存在项目中的阅读资料，本轮无需添加到对话引用。",
                createdAt: date, updatedAt: date.addingTimeInterval(-180))
        ]
        var project = LocalProject(id: projectID, name: "Hermes 资料更新示例", summary: "先查看影响，再更新对话引用。",
            instructions: "用中文回答，区分已验证结果与待完成事项。", createdAt: date, updatedAt: date)
        project.documents = documents
        let profile = ConnectionProfile(id: profileID, name: "个人工作空间",
            serverURL: "https://replacement-preview.hermes.test", model: "hermes-agent", localProjects: [project])
        let activeID = UUID(uuidString: "34000000-0000-0000-0000-000000000201")!
        let conversations = [
            Conversation(id: activeID, title: "进行中 · 本周产品交付与资料更新计划",
                messages: [ChatMessage(role: .user, content: "请结合项目约定和验收清单，整理本周交付计划。", createdAt: date)],
                updatedAt: date, profileID: profileID, workspace: .init(), projectID: projectID,
                referenceDocumentIDs: [documents[0].id, documents[2].id, documents[1].id]),
            Conversation(id: UUID(uuidString: "34000000-0000-0000-0000-000000000202")!,
                title: "已归档 · 上一轮发布边界和验收约定",
                messages: [ChatMessage(role: .assistant, content: "保留上一轮讨论记录，资料引用可单独检查。", createdAt: date)],
                updatedAt: date.addingTimeInterval(-60), profileID: profileID, workspace: .init(archived: true),
                projectID: projectID, referenceDocumentIDs: [documents[2].id, documents[0].id]),
            Conversation(id: UUID(uuidString: "34000000-0000-0000-0000-000000000203")!,
                title: "回收站 · 早期方案讨论与后续恢复检查",
                messages: [ChatMessage(role: .user, content: "恢复后继续讨论时，应使用已确认的参考资料。", createdAt: date)],
                updatedAt: date.addingTimeInterval(-120), profileID: profileID,
                workspace: .init(trashedAt: date.addingTimeInterval(-30)), projectID: projectID,
                referenceDocumentIDs: [documents[1].id, documents[0].id])
        ]
        let library = ConnectionLibrary(profiles: [profile], activeID: profileID,
            selectedConversations: [profileID.uuidString: activeID.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        try JSONEncoder().encode(conversations).write(to: directory.appendingPathComponent("conversations.json"), options: .atomic)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplacementVisualNetworkGuard.self]
        let model = AppModel(defaults: defaults, directory: directory, credentials: MemoryCredentials(),
            sessionConfiguration: configuration)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertFalse(model.settings.isConfigured)
        XCTAssertEqual(model.projects.first?.documents.count, 4)
        XCTAssertEqual(model.projectDocumentConversations(projectID: projectID, profileID: profileID).count, 3)
        return ReplacementVisualFixture(model: model, profileID: profileID, projectID: projectID,
            documents: documents, conversationIDs: Set(conversations.map(\.id)))
    }
}

private struct ReplacementVisualFixture {
    let model: AppModel
    let profileID: UUID
    let projectID: UUID
    let documents: [ProjectDocument]
    let conversationIDs: Set<UUID>
}

private final class ReplacementVisualNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("资料引用替换布局检查不应发送网络请求。")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
