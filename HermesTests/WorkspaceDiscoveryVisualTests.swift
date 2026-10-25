import XCTest
import SwiftUI
import UIKit
@testable import Hermes

/// Isolated layout evidence only; rendering does not navigate, alter a draft, or send a request.
final class WorkspaceDiscoveryVisualTests: XCTestCase {
    @MainActor func testWorkspaceHomeCompactLayout() async throws {
        let fixture = try makeFixture()
        let before = DiscoveryVisualState(model: fixture.model)
        let snapshot = try fixture.model.workspaceSnapshot()
        XCTAssertEqual(snapshot.draftItems().count, 3)
        XCTAssertEqual(snapshot.conversations.filter { !$0.isArchived }.count, 2)
        let view = NavigationStack {
            WorkspaceHomeView(onOpenChat: { _ in XCTFail("渲染工作台不应打开对话。") })
        }.environmentObject(fixture.model)
        try await snapshotView(view, size: CGSize(width: 390, height: 1200), name: "home-compact")
        assertUnchanged(fixture, before: before)
    }

    @MainActor func testWorkspaceSearchFiveKindsWideLayout() async throws {
        let fixture = try makeFixture()
        let before = DiscoveryVisualState(model: fixture.model)
        let report = WorkspaceSearch.run(try fixture.model.workspaceSnapshot(), query: "发布")
        XCTAssertEqual(report.total, 5)
        for kind in WorkspaceSearchKind.allCases { XCTAssertEqual(report.counts[kind], 1) }
        XCTAssertFalse(report.results.contains { $0.archived })
        XCTAssertFalse(report.results.contains { $0.title.contains("其他连接") || $0.title.contains("回收站") })
        let view = NavigationStack {
            WorkspaceSearchView(initialQuery: "发布", onOpenChat: { _ in XCTFail("渲染统一检索不应打开对话。") })
        }.environmentObject(fixture.model)
        try await snapshotView(view, size: CGSize(width: 1024, height: 1200), name: "search-wide")
        assertUnchanged(fixture, before: before)
    }

    @MainActor func testWorkspaceDraftListCompactLayout() async throws {
        let fixture = try makeFixture()
        let before = DiscoveryVisualState(model: fixture.model)
        let snapshot = try fixture.model.workspaceSnapshot()
        let items = snapshot.draftItems()
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first?.destination, .draft(nil))
        XCTAssertEqual(snapshot.draftItems(includeArchived: true).count, 4)
        let view = NavigationStack {
            WorkspaceDraftListView(onOpenChat: { _ in XCTFail("渲染草稿列表不应打开或修改草稿。") })
        }.environmentObject(fixture.model)
        try await snapshotView(view, size: CGSize(width: 390, height: 1100), name: "drafts-compact")
        assertUnchanged(fixture, before: before)
    }

    @MainActor private func assertUnchanged(_ fixture: DiscoveryVisualFixture, before: DiscoveryVisualState,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.model.activeProfileID, before.profileID, file: file, line: line)
        XCTAssertEqual(fixture.model.profiles, before.profiles, file: file, line: line)
        XCTAssertEqual(fixture.model.projects, before.projects, file: file, line: line)
        XCTAssertEqual(fixture.model.conversations, before.conversations, file: file, line: line)
        XCTAssertEqual(fixture.model.trashedConversations, before.trashedConversations, file: file, line: line)
        XCTAssertEqual(fixture.model.selectedID, before.selectedID, file: file, line: line)
        XCTAssertEqual(fixture.model.draft, before.draft, file: file, line: line)
        XCTAssertFalse(fixture.model.isSending, file: file, line: line)
        XCTAssertFalse(fixture.model.needsRecovery, file: file, line: line)
        XCTAssertFalse(fixture.model.settings.isConfigured, file: file, line: line)
    }

    @MainActor private func snapshotView<V: View>(_ view: V, size: CGSize, name: String) async throws {
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
        // Allow the search task and navigation bar to finish their initial layout.
        try await Task.sleep(for: .milliseconds(1000))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, size.width, accuracy: 1)
        XCTAssertEqual(image.size.height, size.height, accuracy: 1)
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 1_000)
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v4-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func makeFixture() throws -> DiscoveryVisualFixture {
        let suite = "HermesWorkspaceDiscoveryVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let date = Date(timeIntervalSince1970: 1_792_600_000)
        let profileID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let foreignID = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
        let projectID = UUID(uuidString: "40000000-0000-0000-0000-000000000101")!
        let otherProjectID = UUID(uuidString: "40000000-0000-0000-0000-000000000102")!
        let activeID = UUID(uuidString: "40000000-0000-0000-0000-000000000201")!
        let secondID = UUID(uuidString: "40000000-0000-0000-0000-000000000202")!
        let archivedID = UUID(uuidString: "40000000-0000-0000-0000-000000000203")!
        let trashID = UUID(uuidString: "40000000-0000-0000-0000-000000000204")!
        let foreignConversationID = UUID(uuidString: "40000000-0000-0000-0000-000000000205")!
        let project = LocalProject(id: projectID, name: "发布工作区", summary: "整理交付计划和验收依据。",
            instructions: "保留来源，说明验证范围。", createdAt: date, updatedAt: date,
            knowledgeDocuments: [ProjectDocument(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000301")!,
                title: "发布验收清单", body: "核对交付内容、自动测试与待完成的设备验收。",
                createdAt: date, updatedAt: date)])
        let otherProject = LocalProject(id: otherProjectID, name: "产品访谈", summary: "积累问题、反馈与后续行动。",
            instructions: "区分观察和推测。", createdAt: date, updatedAt: date.addingTimeInterval(-60),
            knowledgeDocuments: [ProjectDocument(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000302")!,
                title: "访谈提纲", body: "了解当前流程、遇到的问题和已有做法。",
                createdAt: date, updatedAt: date.addingTimeInterval(-60))])
        let profile = ConnectionProfile(id: profileID, name: "个人工作空间",
            serverURL: "https://discovery-preview.hermes.test", model: "hermes-agent", localProjects: [project, otherProject])
        let foreign = ConnectionProfile(id: foreignID, name: "其他连接",
            serverURL: "https://foreign-discovery-preview.hermes.test", model: "hermes-agent",
            localProjects: [LocalProject(name: "其他连接的发布项目", summary: "不进入当前检索范围。", instructions: "",
                createdAt: date, updatedAt: date)])
        let active = Conversation(id: activeID, title: "发布行动清单",
            messages: [ChatMessage(id: UUID(uuidString: "40000000-0000-0000-0000-000000000401")!, role: .assistant,
                content: "发布前先检查变更与证据，再安排后续设备验收。",
                createdAt: date, bookmark: .init(createdAt: date, note: "交付时保留验证边界。"))],
            updatedAt: date, profileID: profileID, workspace: .init(tags: ["进行中"]), projectID: projectID)
        let second = Conversation(id: secondID, title: "产品访谈与整理",
            messages: [ChatMessage(role: .user, content: "先整理发现，再明确下一轮访谈问题。", createdAt: date.addingTimeInterval(-60))],
            updatedAt: date.addingTimeInterval(-60), profileID: profileID,
            workspace: .init(tags: ["访谈"]), projectID: otherProjectID)
        let archived = Conversation(id: archivedID, title: "已归档 · 发布复盘",
            messages: [ChatMessage(role: .assistant, content: "发布复盘属于已归档范围。", createdAt: date.addingTimeInterval(-120))],
            updatedAt: date.addingTimeInterval(-120), profileID: profileID,
            workspace: .init(archived: true), projectID: projectID)
        let trash = Conversation(id: trashID, title: "回收站 · 发布旧方案",
            messages: [ChatMessage(role: .user, content: "发布旧方案在回收站中。", createdAt: date.addingTimeInterval(-180))],
            updatedAt: date.addingTimeInterval(-180), profileID: profileID,
            workspace: .init(trashedAt: date.addingTimeInterval(-30)), projectID: projectID)
        let foreignConversation = Conversation(id: foreignConversationID, title: "其他连接 · 发布讨论",
            messages: [ChatMessage(role: .assistant, content: "其他连接的发布内容不能进入当前工作区。", createdAt: date)],
            updatedAt: date, profileID: foreignID)
        let library = ConnectionLibrary(profiles: [profile, foreign], activeID: profileID,
            selectedConversations: [profileID.uuidString: activeID.uuidString])
        let drafts = [
            DraftStore.localKey(profileID: profileID, conversationID: nil): "发布前再核对一次交付清单。",
            DraftStore.localKey(profileID: profileID, conversationID: activeID): "整理本周行动，补齐记录。",
            DraftStore.localKey(profileID: profileID, conversationID: secondID): "继续梳理访谈问题。",
            DraftStore.localKey(profileID: profileID, conversationID: archivedID): "发布复盘的归档草稿。",
            DraftStore.localKey(profileID: profileID, conversationID: trashID): "发布旧方案的回收站草稿。",
            DraftStore.localKey(profileID: foreignID, conversationID: foreignConversationID): "其他连接的发布草稿。",
            "\(profileID.uuidString)/remote/server-session": "发布相关的服务端会话草稿。"
        ]
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        try JSONEncoder().encode([active, second, archived, trash, foreignConversation])
            .write(to: directory.appendingPathComponent("conversations.json"), options: .atomic)
        try JSONEncoder().encode(drafts).write(to: directory.appendingPathComponent("drafts.json"), options: .atomic)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceDiscoveryVisualNetworkGuard.self]
        let model = AppModel(defaults: defaults, directory: directory, credentials: MemoryCredentials(),
            sessionConfiguration: configuration)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertFalse(model.settings.isConfigured)
        XCTAssertEqual(model.profiles.count, 2)
        XCTAssertEqual(model.projects.count, 2)
        XCTAssertEqual(model.projects.reduce(0) { $0 + $1.documents.count }, 2)
        XCTAssertEqual(model.conversations.count, 3)
        XCTAssertEqual(model.conversations.filter(\.isArchived).count, 1)
        XCTAssertEqual(model.trashedConversations.count, 1)
        XCTAssertEqual(model.selectedID, activeID)
        XCTAssertEqual(model.draft, drafts[DraftStore.localKey(profileID: profileID, conversationID: activeID)])
        return DiscoveryVisualFixture(model: model)
    }
}

private struct DiscoveryVisualFixture {
    let model: AppModel
}

@MainActor private struct DiscoveryVisualState {
    let profileID: UUID
    let profiles: [ConnectionProfile]
    let projects: [LocalProject]
    let conversations: [Conversation]
    let trashedConversations: [Conversation]
    let selectedID: UUID?
    let draft: String

    init(model: AppModel) {
        profileID = model.activeProfileID
        profiles = model.profiles
        projects = model.projects
        conversations = model.conversations
        trashedConversations = model.trashedConversations
        selectedID = model.selectedID
        draft = model.draft
    }
}

private final class WorkspaceDiscoveryVisualNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("工作台、统一检索和草稿布局检查不应发送网络请求。")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
