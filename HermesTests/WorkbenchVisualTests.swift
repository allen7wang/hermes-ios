import XCTest
import SwiftUI
import UIKit
@testable import Hermes

final class WorkbenchVisualTests: XCTestCase {
    @MainActor func testWorkbenchPhoneLayout() async throws {
        let model = try makeModel()
        try await snapshot(AppShell().environmentObject(model), size: CGSize(width: 390, height: 844), name: "workbench-phone")
    }

    @MainActor func testConversationSettingsPhoneLayout() async throws {
        let model = try makeModel()
        let view = ConversationSettingsView(conversationID: model.selectedID, profileID: model.activeProfileID, draftKey: model.draftKey)
            .environmentObject(model)
        try await snapshot(view, size: CGSize(width: 390, height: 844), name: "conversation-settings-phone")
    }

    @MainActor func testServerTasksTabletLayout() async throws {
        let model = try makeModel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VisualServerProtocol.self]
        let client = HermesClient(settings: model.settings, sessionConfiguration: configuration)
        let view = RemoteWorkspaceContent(client: client, embedded: true, initialSection: 1).environmentObject(model)
        try await snapshot(view, size: CGSize(width: 1024, height: 1000), name: "server-tasks-tablet")
    }

    @MainActor private func snapshot<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let controller = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "zh_CN")).preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(900))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.width, 300)
        let data = try XCTUnwrap(image.pngData())
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-v1-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
    }

    @MainActor private func makeModel() throws -> AppModel {
        let suite = "HermesVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("https://preview.hermes.test", forKey: "serverURL")
        defaults.set("hermes-agent", forKey: "model")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let records = [
            Conversation(title: "把 v1.0 发布准备好", messages: [
                ChatMessage(role: .user, content: "帮我整理发布前需要完成的工作。"),
                ChatMessage(role: .assistant, content: "先确认功能与测试，再检查备份兼容、文档和版本号。", bookmark: .init(createdAt: Date(), note: "发布清单"))
            ], updatedAt: Date(), pinned: true, workspace: .init(tags: ["工作", "Hermes"], configuration: .init(systemPrompt: "用中文回答，先给结论。", contextTurns: 6))),
            Conversation(title: "周末的阅读计划", messages: [ChatMessage(role: .assistant, content: "留一点时间，读完一直想读的那本书。")],
                updatedAt: Date(timeIntervalSinceNow: -3600), workspace: .init(tags: ["生活"])),
            Conversation(title: "已完成的灵感笔记", messages: [], updatedAt: Date(timeIntervalSinceNow: -86400), workspace: .init(tags: ["灵感"], archived: true))
        ]
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("conversations.json"))
        let keys = MemoryCredentials(); keys.values["api-server-key"] = "preview-only"
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        return AppModel(defaults: defaults, directory: directory, credentials: keys)
    }
}

private final class VisualServerProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let json = #"{"jobs":[{"id":"weekly","name":"每周研究简报","prompt":"整理本周的研究发现与下一步行动。","state":"running","schedule_display":"每周一 09:00","next_run_at":"2026-10-26T01:00:00Z"},{"id":"review","name":"发布验证提醒","prompt":"检查回归结果和待办。","state":"scheduled","last_status":"failed","last_error":"上次投递失败","schedule_display":"every 1h"},{"id":"reading","name":"晚间阅读","prompt":"推荐一篇值得读的文章。","state":"paused","enabled":false,"schedule_display":"every day at 9pm"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
