import XCTest
import SwiftUI
import UIKit
@testable import Hermes

/// Isolated layout evidence only; rendering does not save a document or perform native interaction.
final class MessageProjectCaptureVisualTests: XCTestCase {
    @MainActor func testMessageCaptureProjectPickerCompactLayout() async throws {
        let fixture = try makeFixture()
        let source = try fixture.model.makeMessageLibraryBatch(fixture.targets, profileID: fixture.profileID)
        let before = ProjectCaptureVisualState(model: fixture.model)
        XCTAssertEqual(fixture.model.projects.count, 2)
        XCTAssertEqual(source.items.count, 3)
        let view = MessageProjectCapturePickerView(source: source,
            onSaved: { _ in XCTFail("渲染项目选择页不应保存资料。") })
            .environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 1100), name: "message-capture-projects-compact")
        assertUnchanged(fixture, before: before)
    }

    @MainActor func testMessageCaptureEditorWideLayout() async throws {
        let fixture = try makeFixture()
        let source = try fixture.model.makeMessageLibraryBatch(fixture.targets, profileID: fixture.profileID)
        let capture = try fixture.model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let before = ProjectCaptureVisualState(model: fixture.model)
        let view = NavigationStack {
            MessageProjectCaptureEditorView(capture: capture,
                onSaved: { _ in XCTFail("渲染资料编辑页不应保存资料。") },
                onFinished: { XCTFail("渲染资料编辑页不应结束采集流程。") })
        }.environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 1024, height: 1200), name: "message-capture-editor-wide")
        assertUnchanged(fixture, before: before)
    }

    @MainActor func testMessageCaptureChangedTargetProjectCompactLayout() async throws {
        let fixture = try makeFixture()
        let source = try fixture.model.makeMessageLibraryBatch(fixture.targets, profileID: fixture.profileID)
        let capture = try fixture.model.prepareMessageProjectCapture(source: source, projectID: fixture.targetProjectID)
        let project = try XCTUnwrap(fixture.model.projects.first { $0.id == fixture.targetProjectID })
        _ = try fixture.model.saveProject(id: project.id, name: project.name,
            summary: "其他窗口已更新目标项目简介；保存前请重新检查目标，保留当前编辑正文。",
            instructions: project.instructions, profileID: fixture.profileID)
        XCTAssertNotEqual(fixture.model.projects.first { $0.id == fixture.targetProjectID }, project)
        let before = ProjectCaptureVisualState(model: fixture.model)
        let view = NavigationStack {
            MessageProjectCaptureEditorView(capture: capture,
                onSaved: { _ in XCTFail("渲染目标变化的编辑页不应保存资料。") },
                onFinished: { XCTFail("渲染冲突页面不应结束采集流程。") })
        }.environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 390, height: 1300), name: "message-capture-conflict-compact")
        assertUnchanged(fixture, before: before)
    }

    @MainActor private func assertUnchanged(_ fixture: ProjectCaptureVisualFixture, before: ProjectCaptureVisualState,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.model.activeProfileID, before.profileID, file: file, line: line)
        XCTAssertEqual(fixture.model.projects, before.projects, file: file, line: line)
        XCTAssertEqual(fixture.model.conversations, before.conversations, file: file, line: line)
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
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v3-9-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func makeFixture() throws -> ProjectCaptureVisualFixture {
        let suite = "HermesMessageProjectCaptureVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let date = Date(timeIntervalSince1970: 1_792_600_000)
        let profileID = UUID(uuidString: "38000000-0000-0000-0000-000000000001")!
        let sourceProjectID = UUID(uuidString: "38000000-0000-0000-0000-000000000101")!
        let targetProjectID = UUID(uuidString: "38000000-0000-0000-0000-000000000102")!
        let activeID = UUID(uuidString: "38000000-0000-0000-0000-000000000201")!
        let archiveID = UUID(uuidString: "38000000-0000-0000-0000-000000000202")!
        let sourceProject = LocalProject(id: sourceProjectID, name: "发布讨论 · 消息来源", summary: "保存进行中讨论和归档复盘。",
            instructions: "保留消息来源和验收范围。", createdAt: date, updatedAt: date,
            knowledgeDocuments: [ProjectDocument(title: "讨论背景", body: "历史讨论仅供本次资料整理参考。", createdAt: date, updatedAt: date)])
        let targetProject = LocalProject(id: targetProjectID, name: "交付知识库 · 接收整理后的资料", summary: "将多段讨论归纳为可复用的项目资料。",
            instructions: "先确认正文，再决定是否为对话添加引用。", createdAt: date, updatedAt: date.addingTimeInterval(-60),
            knowledgeDocuments: [
                ProjectDocument(title: "项目定位", body: "为长期项目保留可检查的资料与对话记录。", createdAt: date, updatedAt: date),
                ProjectDocument(title: "验收清单", body: "逐项记录自动测试、原生交互、真机和服务端验收范围。", createdAt: date, updatedAt: date)
            ])
        let profile = ConnectionProfile(id: profileID, name: "个人工作空间",
            serverURL: "https://project-capture-preview.hermes.test", model: "hermes-agent", localProjects: [sourceProject, targetProject])
        let active = Conversation(id: activeID, title: "进行中 · 新版交付方案与聊天成果整理",
            messages: [
                ChatMessage(id: UUID(uuidString: "38000000-0000-0000-0000-000000000301")!, role: .assistant,
                    content: "## 本轮讨论结论\n\n先选择来源消息，再检查目标项目和资料正文。\n\n- 保留每条消息的原文与来源\n- 收藏备注不进入采集正文\n- 保存后由用户决定是否添加到对话引用",
                    createdAt: date, bookmark: .init(createdAt: date, note: "私有收藏备注：内部待办保留在原消息，不采集到项目资料。")),
                ChatMessage(id: UUID(uuidString: "38000000-0000-0000-0000-000000000302")!, role: .user,
                    content: "这张草图用于说明界面结构。整理为资料时只保留文字，图片继续留在原对话中。",
                    createdAt: date.addingTimeInterval(-60),
                    imageID: UUID(uuidString: "38000000-0000-0000-0000-000000000401")!)
            ], updatedAt: date, profileID: profileID, workspace: .init(tags: ["交付计划"]),
            projectID: sourceProjectID, referenceDocumentIDs: sourceProject.documents.map(\.id))
        let archived = Conversation(id: archiveID, title: "已归档 · 上轮发布的结论、验收边界和改进建议",
            messages: [ChatMessage(id: UUID(uuidString: "38000000-0000-0000-0000-000000000303")!, role: .assistant,
                content: "## 历史复盘\n\n对话中的结论可以整理到其他项目，但需要检查正文和目标容量。自动测试通过的范围与真机、服务端和文件往返验收应分别记录。",
                createdAt: date.addingTimeInterval(-120),
                bookmark: .init(createdAt: date.addingTimeInterval(-90), note: "复盘私有备注：下次补齐系统文件导出检查。"))],
            updatedAt: date.addingTimeInterval(-120), profileID: profileID,
            workspace: .init(tags: ["发布复盘"], archived: true), projectID: sourceProjectID)
        let conversations = [active, archived]
        let library = ConnectionLibrary(profiles: [profile], activeID: profileID,
            selectedConversations: [profileID.uuidString: activeID.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        try JSONEncoder().encode(conversations).write(to: directory.appendingPathComponent("conversations.json"), options: .atomic)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageProjectCaptureVisualNetworkGuard.self]
        let model = AppModel(defaults: defaults, directory: directory, credentials: MemoryCredentials(),
            sessionConfiguration: configuration)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertFalse(model.settings.isConfigured)
        XCTAssertEqual(model.conversations.count, 2)
        XCTAssertEqual(model.conversations.filter(\.isArchived).count, 1)
        XCTAssertEqual(model.selectedID, activeID)
        XCTAssertEqual(model.projects.first { $0.id == targetProjectID }?.documents.count, 2)
        model.draft = "当前对话尚未发送的草稿；采集资料时完整保留。"
        let targets = conversations.flatMap { conversation in
            conversation.messages.map { LocalMessageTarget(conversationID: conversation.id, messageID: $0.id) }
        }
        return ProjectCaptureVisualFixture(model: model, profileID: profileID,
            targetProjectID: targetProjectID, targets: targets)
    }
}

private struct ProjectCaptureVisualFixture {
    let model: AppModel
    let profileID: UUID
    let targetProjectID: UUID
    let targets: [LocalMessageTarget]
}

@MainActor private struct ProjectCaptureVisualState {
    let profileID: UUID
    let projects: [LocalProject]
    let conversations: [Conversation]
    let selectedID: UUID?
    let draft: String

    init(model: AppModel) {
        profileID = model.activeProfileID
        projects = model.projects
        conversations = model.conversations
        selectedID = model.selectedID
        draft = model.draft
    }
}

private final class MessageProjectCaptureVisualNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("消息采集到项目资料的布局检查不应发送网络请求。")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
