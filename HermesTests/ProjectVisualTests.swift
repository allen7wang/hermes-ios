import XCTest
import SwiftUI
import UIKit
@testable import Hermes

/// Layout evidence uses only this fixture's temporary files and in-memory credentials.
/// These snapshots are not a substitute for iPhone/iPad touch interaction testing.
final class ProjectVisualTests: XCTestCase {
    @MainActor func testProjectListCompactLayout() async throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.model.projects.count, 3)
        XCTAssertFalse(fixture.model.projects.contains { $0.name == "另一个连接的项目" })
        try await snapshot(ProjectWorkspaceView().environmentObject(fixture.model),
            size: CGSize(width: 390, height: 844), name: "projects-compact")
    }

    @MainActor func testProjectWorkbenchWideLayout() async throws {
        let fixture = try makeFixture()
        let active = fixture.model.conversations.filter {
            $0.projectID == fixture.releaseProjectID && !$0.isArchived
        }
        XCTAssertEqual(active.count, 2)
        let view = NavigationStack {
            HistoryView(embedded: true, initialProject: .project(fixture.releaseProjectID))
        }.environmentObject(fixture.model)
        try await snapshot(view, size: CGSize(width: 1024, height: 1000), name: "project-workbench-wide")
    }

    @MainActor func testProjectContextPreviewCompactLayout() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.select(fixture.releaseConversationID)
        model.draft = "根据项目目标，整理这次发布的验收步骤和待完成事项。"
        let preview = try model.previewNextRequest(model.draft, hasImage: false, expectedDraftKey: model.draftKey)
        XCTAssertEqual(preview.plan.project?.id, fixture.releaseProjectID)
        XCTAssertTrue(preview.plan.effectiveSystemPrompt.contains("项目指令"))
        XCTAssertTrue(preview.plan.effectiveSystemPrompt.contains("标明验证结果和未完成项"))
        XCTAssertTrue(preview.plan.effectiveSystemPrompt.contains("先给结论，再列检查清单"))
        try await snapshot(ChatContextPreviewView(preview: preview).environmentObject(model),
            size: CGSize(width: 390, height: 844), name: "project-context-compact")
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
        try await Task.sleep(for: .milliseconds(900))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, size.width, accuracy: 1)
        XCTAssertEqual(image.size.height, size.height, accuracy: 1)
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 1_000)
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v2-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func makeFixture() throws -> ProjectVisualFixture {
        let suite = "HermesProjectVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let date = Date(timeIntervalSince1970: 1_792_713_600)
        let profileID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let otherProfileID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let releaseID = UUID(uuidString: "20000000-0000-0000-0000-000000000101")!
        let readingID = UUID(uuidString: "20000000-0000-0000-0000-000000000102")!
        let travelID = UUID(uuidString: "20000000-0000-0000-0000-000000000103")!
        let otherProjectID = UUID(uuidString: "20000000-0000-0000-0000-000000000104")!
        let conversationID = UUID(uuidString: "20000000-0000-0000-0000-000000000201")!
        let release = LocalProject(id: releaseID, name: "Hermes 2.0",
            summary: "把版本目标、验收与发布放在同一个项目里。",
            instructions: "你是 Hermes iOS 发布搭档。\n用中文回答，先列行动步骤；标明验证结果和未完成项。",
            createdAt: date, updatedAt: date)
        let reading = LocalProject(id: readingID, name: "阅读与研究",
            summary: "积累资料、提炼观点，并保留值得追问的问题。", instructions: "区分事实、推断和待验证的观点。",
            createdAt: date, updatedAt: date.addingTimeInterval(-60))
        let travel = LocalProject(id: travelID, name: "旅行计划",
            summary: "慢慢整理下一次出发的灵感。", instructions: "",
            createdAt: date, updatedAt: date.addingTimeInterval(-120))
        let hidden = LocalProject(id: otherProjectID, name: "另一个连接的项目", summary: "独立连接的示例数据", instructions: "",
            createdAt: date, updatedAt: date)
        let profile = ConnectionProfile(id: profileID, name: "个人工作空间", serverURL: "https://project-preview.hermes.test",
            model: "hermes-agent", localProjects: [release, reading, travel])
        let otherProfile = ConnectionProfile(id: otherProfileID, name: "隔离示例连接", serverURL: "https://other-preview.hermes.test",
            model: "hermes-agent", localProjects: [hidden])
        let library = ConnectionLibrary(profiles: [profile, otherProfile], activeID: profileID,
            selectedConversations: [profileID.uuidString: conversationID.uuidString])
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        let records = [
            Conversation(id: conversationID, title: "v2.0 发布清单与验收", messages: [
                ChatMessage(role: .user, content: "这次大版本发布前，需要完成哪些检查？", createdAt: date),
                ChatMessage(role: .assistant, content: "先完成项目工作区，再核对指令预览、备份兼容与回归结果。", createdAt: date,
                    bookmark: .init(createdAt: date, note: "发布前逐项验收"))
            ], updatedAt: date, profileID: profileID, pinned: true,
                workspace: .init(tags: ["发布", "Hermes"], configuration: .init(systemPrompt: "先给结论，再列检查清单。", contextTurns: 6)), projectID: releaseID),
            Conversation(title: "上下文与备份兼容", messages: [
                ChatMessage(role: .assistant, content: "用隔离示例验证项目指令与对话指令，并检查旧备份迁移。", createdAt: date)
            ], updatedAt: date.addingTimeInterval(-3_600), profileID: profileID,
                workspace: .init(tags: ["验证"]), projectID: releaseID),
            Conversation(title: "已完成的发布复盘", messages: [
                ChatMessage(role: .assistant, content: "把上一次发布的结论留在这里，供下一次参考。", createdAt: date)
            ], updatedAt: date.addingTimeInterval(-86_400), profileID: profileID,
                workspace: .init(tags: ["复盘"], archived: true), projectID: releaseID),
            Conversation(title: "读完之后，留下三个问题", messages: [
                ChatMessage(role: .assistant, content: "记录作者的结论、证据和仍需追问的地方。", createdAt: date)
            ], updatedAt: date.addingTimeInterval(-7_200), profileID: profileID, projectID: readingID),
            Conversation(title: "还没有归入项目的想法", messages: [], updatedAt: date.addingTimeInterval(-10_800), profileID: profileID),
            Conversation(title: "其他连接的示例对话", messages: [], updatedAt: date, profileID: otherProfileID, projectID: otherProjectID)
        ]
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("conversations.json"), options: .atomic)
        let credentials = MemoryCredentials()
        credentials.values[profile.credentialAccount] = "project-layout-fixture-only"
        credentials.values[otherProfile.credentialAccount] = "other-layout-fixture-only"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectVisualNetworkGuard.self]
        let model = AppModel(defaults: defaults, directory: directory, credentials: credentials, sessionConfiguration: configuration)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertEqual(model.conversations.count, 5)
        return ProjectVisualFixture(model: model, releaseProjectID: releaseID, releaseConversationID: conversationID)
    }
}

private struct ProjectVisualFixture {
    let model: AppModel
    let releaseProjectID: UUID
    let releaseConversationID: UUID
}

private final class ProjectVisualNetworkGuard: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("本机项目布局检查不应发送网络请求。")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
