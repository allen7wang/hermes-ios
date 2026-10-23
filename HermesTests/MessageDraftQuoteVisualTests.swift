import XCTest
import SwiftUI
import UIKit
@testable import Hermes

/// Isolated layout evidence only; rendering does not apply a quote or send a request.
final class MessageDraftQuoteVisualTests: XCTestCase {
    @MainActor func testDraftQuoteAppendCompactLayout() async throws {
        let fixture = try makeFixture()
        let review = try fixture.model.makeMessageDraftQuote(fixture.targets, profileID: fixture.profileID)
        let before = DraftQuoteVisualState(model: fixture.model)
        let view = MessageDraftQuoteReviewView(snapshot: review,
            onApplied: { XCTFail("渲染引用确认页不应写入草稿。") },
            onShowDraft: { XCTFail("渲染引用确认页不应跳转对话。") })
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 1200), name: "draft-quote-append-compact")
        assertUnchanged(fixture, before: before)
    }

    @MainActor func testDraftQuoteReplaceWideLayout() async throws {
        let fixture = try makeFixture()
        let review = try fixture.model.makeMessageDraftQuote(fixture.targets, profileID: fixture.profileID)
        let before = DraftQuoteVisualState(model: fixture.model)
        let view = MessageDraftQuoteReviewView(snapshot: review, initialMode: .replace,
            onApplied: { XCTFail("渲染替换确认页不应覆盖草稿。") },
            onShowDraft: { XCTFail("渲染替换确认页不应跳转对话。") })
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 1024, height: 1100), name: "draft-quote-replace-wide")
        assertUnchanged(fixture, before: before)
    }

    @MainActor func testDraftQuoteChangedDraftConflictCompactLayout() async throws {
        let fixture = try makeFixture()
        let originalDraft = fixture.model.draft
        let review = try fixture.model.makeMessageDraftQuote(fixture.targets, profileID: fixture.profileID)
        fixture.model.draft = "其他窗口刚刚更新了这份草稿。\n\n保留最新输入，重新检查来源消息后再引用。"
        XCTAssertNotEqual(fixture.model.draft, originalDraft)
        let before = DraftQuoteVisualState(model: fixture.model)
        let view = MessageDraftQuoteReviewView(snapshot: review,
            onApplied: { XCTFail("失效的引用确认页不应写入草稿。") },
            onShowDraft: { XCTFail("渲染冲突页面不应跳转对话。") })
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 1200), name: "draft-quote-conflict-compact")
        assertUnchanged(fixture, before: before)
    }

    @MainActor private func assertUnchanged(_ fixture: DraftQuoteVisualFixture, before: DraftQuoteVisualState,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.model.activeProfileID, before.profileID, file: file, line: line)
        XCTAssertEqual(fixture.model.conversations, before.conversations, file: file, line: line)
        XCTAssertEqual(fixture.model.projects, before.projects, file: file, line: line)
        XCTAssertEqual(fixture.model.selectedID, before.selectedID, file: file, line: line)
        XCTAssertEqual(fixture.model.draft, before.draft, file: file, line: line)
        XCTAssertFalse(fixture.model.isSending, file: file, line: line)
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
        try await Task.sleep(for: .milliseconds(1000))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, size.width, accuracy: 1)
        XCTAssertEqual(image.size.height, size.height, accuracy: 1)
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 1_000)
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v3-7-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func makeFixture() throws -> DraftQuoteVisualFixture {
        let suite = "HermesMessageDraftQuoteVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let date = Date(timeIntervalSince1970: 1_792_600_000)
        let profileID = UUID(uuidString: "36000000-0000-0000-0000-000000000001")!
        let projectID = UUID(uuidString: "36000000-0000-0000-0000-000000000101")!
        let targetID = UUID(uuidString: "36000000-0000-0000-0000-000000000201")!
        let sourceID = UUID(uuidString: "36000000-0000-0000-0000-000000000202")!
        let project = LocalProject(id: projectID, name: "Hermes 发布计划与消息复用", summary: "挑选历史消息，确认目标和最终草稿后再继续讨论。",
            instructions: "用中文回答，记录来源及验收边界。", createdAt: date, updatedAt: date)
        let profile = ConnectionProfile(id: profileID, name: "个人工作空间",
            serverURL: "https://draft-quote-preview.hermes.test", model: "hermes-agent", localProjects: [project])
        let target = Conversation(id: targetID, title: "进行中 · 本轮迭代的交付安排与后续讨论",
            messages: [ChatMessage(id: UUID(uuidString: "36000000-0000-0000-0000-000000000301")!, role: .user,
                content: "先保留这次讨论的目标，等历史结论整理好后再继续。", createdAt: date)],
            updatedAt: date, profileID: profileID, workspace: .init(tags: ["发布计划"]), projectID: projectID)
        let source = Conversation(id: sourceID, title: "已归档 · 上一轮发布复盘、资料引用边界和真机验收说明",
            messages: [
                ChatMessage(id: UUID(uuidString: "36000000-0000-0000-0000-000000000302")!, role: .assistant,
                    content: "## 上次复盘结论\n\n整理历史消息时，保留原文和来源。\n\n- 自动测试结果应与验证范围一起记录\n- 不把草稿中的引用自动发送\n- 后续补充文件导出与真机验收结果",
                    createdAt: date.addingTimeInterval(-60),
                    bookmark: .init(createdAt: date.addingTimeInterval(-30), note: "私有收藏备注：补充团队内部的待办，不应带入引用草稿。")),
                ChatMessage(id: UUID(uuidString: "36000000-0000-0000-0000-000000000303")!, role: .user,
                    content: "请结合这张草图说明界面布局。历史引用只保留文字，图片仍保存在原对话中。",
                    createdAt: date.addingTimeInterval(-120),
                    imageID: UUID(uuidString: "36000000-0000-0000-0000-000000000401")!,
                    bookmark: .init(createdAt: date.addingTimeInterval(-90), note: "草图仅作本机参考。")),
                ChatMessage(id: UUID(uuidString: "36000000-0000-0000-0000-000000000304")!, role: .assistant,
                    content: "下一轮可先完善消息复用，再逐项验收草稿保留、来源变化检查与上下文预览。",
                    createdAt: date.addingTimeInterval(-180))
            ], updatedAt: date.addingTimeInterval(-60), profileID: profileID,
            workspace: .init(tags: ["发布复盘", "待验证"], archived: true), projectID: projectID)
        let library = ConnectionLibrary(profiles: [profile], activeID: profileID,
            selectedConversations: [profileID.uuidString: targetID.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        try JSONEncoder().encode([target, source]).write(to: directory.appendingPathComponent("conversations.json"), options: .atomic)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DraftQuoteVisualNetworkGuard.self]
        let model = AppModel(defaults: defaults, directory: directory, credentials: MemoryCredentials(),
            sessionConfiguration: configuration)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertFalse(model.settings.isConfigured)
        XCTAssertEqual(model.selectedID, targetID)
        XCTAssertEqual(model.conversations.count, 2)
        XCTAssertEqual(model.conversations.filter(\.isArchived).count, 1)
        model.draft = "请结合上一轮复盘，整理本次发布的行动清单。\n\n已有草稿中的目标和待办需要保留。"
        let targets = source.messages.map { LocalMessageTarget(conversationID: sourceID, messageID: $0.id) }
        return DraftQuoteVisualFixture(model: model, profileID: profileID, targets: targets)
    }
}

private struct DraftQuoteVisualFixture {
    let model: AppModel
    let profileID: UUID
    let targets: [LocalMessageTarget]
}

@MainActor private struct DraftQuoteVisualState {
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

private final class DraftQuoteVisualNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("消息引用到草稿的布局检查不应发送网络请求。")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
