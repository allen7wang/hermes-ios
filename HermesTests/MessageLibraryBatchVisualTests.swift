import XCTest
import SwiftUI
import UIKit
@testable import Hermes

/// Isolated layout evidence only; rendering does not perform native clicks or export a file.
final class MessageLibraryBatchVisualTests: XCTestCase {
    @MainActor func testMessageLibrarySelectionCompactLayout() async throws {
        let fixture = try makeFixture()
        let before = BatchVisualState(model: fixture.model)
        let bookmarks = MessageLibrary.items(in: fixture.model.conversations, filter: .bookmarks,
            projects: fixture.model.projects)
        XCTAssertEqual(bookmarks.count, 3)
        XCTAssertEqual(bookmarks.filter(\.conversationArchived).count, 1)
        let view = MessageLibraryView(embedded: true, onOpen: { _ in }, selecting: true)
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 1100), name: "message-batch-select-compact")
        assertUnchanged(fixture, before: before)
    }

    @MainActor func testMessageLibraryBatchExportCompactLayout() async throws {
        let fixture = try makeFixture()
        let before = BatchVisualState(model: fixture.model)
        let batch = try fixture.model.makeMessageLibraryBatch(fixture.targets, profileID: fixture.profileID)
        XCTAssertEqual(batch.items.count, 4)
        let view = MessageLibraryBatchExportView(snapshot: batch).environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 1100), name: "message-batch-export-compact")
        assertUnchanged(fixture, before: before)
    }

    @MainActor func testMessageLibraryBookmarkRemovalReviewWideLayout() async throws {
        let fixture = try makeFixture()
        let before = BatchVisualState(model: fixture.model)
        let batch = try fixture.model.makeMessageLibraryBatch(fixture.targets, profileID: fixture.profileID)
        XCTAssertEqual(batch.items.count, 4)
        let view = MessageLibraryBookmarkReviewView(snapshot: batch, operation: .remove,
            onApplied: { _ in XCTFail("渲染确认页面不应应用收藏变更。") })
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 1024, height: 1100), name: "message-batch-bookmarks-wide")
        assertUnchanged(fixture, before: before)
    }

    @MainActor private func assertUnchanged(_ fixture: BatchVisualFixture, before: BatchVisualState,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.model.activeProfileID, before.profileID, file: file, line: line)
        XCTAssertEqual(fixture.model.conversations, before.conversations, file: file, line: line)
        XCTAssertEqual(fixture.model.projects, before.projects, file: file, line: line)
        XCTAssertEqual(fixture.model.selectedID, before.selectedID, file: file, line: line)
        XCTAssertEqual(fixture.model.draft, before.draft, file: file, line: line)
        XCTAssertFalse(fixture.model.needsRecovery, file: file, line: line)
        XCTAssertFalse(fixture.model.settings.isConfigured, file: file, line: line)
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
        // The library resolves its search task after the first layout pass.
        try await Task.sleep(for: .milliseconds(1100))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, size.width, accuracy: 1)
        XCTAssertEqual(image.size.height, size.height, accuracy: 1)
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 1_000)
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v3-5-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func makeFixture() throws -> BatchVisualFixture {
        let suite = "HermesMessageBatchVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let date = Date(timeIntervalSince1970: 1_792_600_000)
        let profileID = UUID(uuidString: "35000000-0000-0000-0000-000000000001")!
        let projectID = UUID(uuidString: "35000000-0000-0000-0000-000000000101")!
        let activeID = UUID(uuidString: "35000000-0000-0000-0000-000000000201")!
        let archiveID = UUID(uuidString: "35000000-0000-0000-0000-000000000202")!
        let project = LocalProject(id: projectID, name: "Hermes 消息整理与交付复盘", summary: "跨对话挑选消息，确认后导出或整理收藏。",
            instructions: "保留上下文，清楚记录验收范围。", createdAt: date, updatedAt: date)
        let profile = ConnectionProfile(id: profileID, name: "个人工作空间",
            serverURL: "https://message-batch-preview.hermes.test", model: "hermes-agent", localProjects: [project])
        let active = Conversation(id: activeID,
            title: "进行中 · 发布前的功能清单、验证记录与消息归档整理计划",
            messages: [
                ChatMessage(id: UUID(uuidString: "35000000-0000-0000-0000-000000000301")!, role: .assistant,
                    content: "## 本轮交付清单\n\n先挑选消息，再核对导出内容。\n\n- 保留消息来源与原文\n- 收藏备注默认不导出\n- 图片仅显示未包含提示",
                    createdAt: date, bookmark: .init(createdAt: date, note: "私有备注：交付前补充本机验收结果，暂不对外分享。")),
                ChatMessage(id: UUID(uuidString: "35000000-0000-0000-0000-000000000302")!, role: .user,
                    content: "请把这张草图和发布约定一起留作参考，后续再补充真机验收记录。",
                    createdAt: date.addingTimeInterval(-60),
                    imageID: UUID(uuidString: "35000000-0000-0000-0000-000000000401")!,
                    bookmark: .init(createdAt: date.addingTimeInterval(-60), note: "草图原件保留在本机，导出只包含文字。")),
                ChatMessage(id: UUID(uuidString: "35000000-0000-0000-0000-000000000303")!, role: .assistant,
                    content: "这条消息尚未收藏，可与收藏消息一起选中后统一整理。",
                    createdAt: date.addingTimeInterval(-120))
            ], updatedAt: date, profileID: profileID,
            workspace: .init(tags: ["发布计划", "待复盘"]), projectID: projectID)
        let archived = Conversation(id: archiveID,
            title: "已归档 · 上一轮发布中的重要结论与后续改进建议",
            messages: [ChatMessage(id: UUID(uuidString: "35000000-0000-0000-0000-000000000304")!, role: .assistant,
                content: "## 复盘结论\n\n自动测试通过后，仍需分别记录文件导出、原生交互和真机验证结果。",
                createdAt: date.addingTimeInterval(-180),
                bookmark: .init(createdAt: date.addingTimeInterval(-180), note: "复盘参考：保留原消息，整理收藏不会删除对话。"))],
            updatedAt: date.addingTimeInterval(-180), profileID: profileID,
            workspace: .init(tags: ["复盘"], archived: true), projectID: projectID)
        let conversations = [active, archived]
        let library = ConnectionLibrary(profiles: [profile], activeID: profileID,
            selectedConversations: [profileID.uuidString: activeID.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        try JSONEncoder().encode(conversations).write(to: directory.appendingPathComponent("conversations.json"), options: .atomic)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageBatchVisualNetworkGuard.self]
        let model = AppModel(defaults: defaults, directory: directory, credentials: MemoryCredentials(),
            sessionConfiguration: configuration)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertFalse(model.settings.isConfigured)
        XCTAssertEqual(model.conversations.count, 2)
        XCTAssertEqual(model.conversations.filter(\.isArchived).count, 1)
        model.draft = "保留这份尚未发送的发布草稿。"
        let targets = conversations.flatMap { conversation in
            conversation.messages.map { LocalMessageTarget(conversationID: conversation.id, messageID: $0.id) }
        }
        return BatchVisualFixture(model: model, profileID: profileID, targets: targets)
    }
}

private struct BatchVisualFixture {
    let model: AppModel
    let profileID: UUID
    let targets: [LocalMessageTarget]
}

@MainActor private struct BatchVisualState {
    let profileID: UUID
    let conversations: [Conversation]
    let projects: [LocalProject]
    let selectedID: UUID?
    let draft: String

    init(model: AppModel) {
        profileID = model.activeProfileID
        conversations = model.conversations
        projects = model.projects
        selectedID = model.selectedID
        draft = model.draft
    }
}

private final class MessageBatchVisualNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("消息批量整理布局检查不应发送网络请求。")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
