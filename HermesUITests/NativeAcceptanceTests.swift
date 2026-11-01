import XCTest

/// Native XCUIAutomation actions against isolated local data; never a substitute for a real API run.
final class NativeAcceptanceTests: XCTestCase {
    private var app: XCUIApplication!
    private let current = "10000000-0000-0000-0000-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if let app {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Final accessibility tree"
            tree.lifetime = .keepAlways
            add(tree)
            capture("Final native screen")
            app.terminate()
        }
    }

    private func launch(run: String = UUID().uuidString, empty: Bool = false, draftFailure: Bool = false) {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["HERMES_UI_TESTING": "1", "HERMES_UI_RUN": run,
                                 "HERMES_UI_EMPTY": empty ? "1" : "0",
                                 "HERMES_UI_DRAFT_FAILURE": draftFailure ? "1" : "0"]
        app.launch()
        XCTAssertTrue(app.buttons["home-new-chat"].waitForExistence(timeout: 15))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing: \(element)", file: file, line: line)
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, file: file, line: line)
        element.tap()
    }

    private func search(_ query: String) {
        tap(app.buttons["home-search"])
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 3) { app.swipeDown() }
        tap(field)
        field.typeText(query + "\n")
    }

    private var composer: XCUIElement { app.descendants(matching: .any)["chat-composer"].firstMatch }

    func testNativeSearchScopesFiltersAndOpensAllFiveResultTypes() {
        launch()
        search("nebula")
        let project = app.buttons["workspace-search-project/10000000-0000-0000-0000-000000000010"]
        tap(project)
        XCTAssertTrue(app.navigationBars["nebula project"].waitForExistence(timeout: 10))
        capture("Opened project search result")
        app.navigationBars.buttons.firstMatch.tap()
        let document = app.buttons["workspace-search-document/10000000-0000-0000-0000-000000000010/10000000-0000-0000-0000-000000000011"]
        tap(document)
        XCTAssertTrue(app.navigationBars["资料详情"].waitForExistence(timeout: 10))
        capture("Opened document search result")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(app.buttons["workspace-search-conversation/10000000-0000-0000-0000-000000000002"].exists)
        tap(app.switches["search-include-archived"])
        let archived = app.buttons["workspace-search-conversation/10000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(archived.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["workspace-search-conversation/10000000-0000-0000-0000-000000000003"].exists)
        XCTAssertFalse(app.buttons["workspace-search-conversation/10000000-0000-0000-0000-000000000004"].exists)
        tap(archived)
        XCTAssertTrue(app.buttons["恢复"].waitForExistence(timeout: 10))
        XCTAssertFalse(composer.isEnabled)
        capture("Archived result cannot send")
    }

    func testNativeMessageAndDraftResultsPreserveInputAcrossRestart() {
        let run = UUID().uuidString
        launch(run: run)
        search("nebula original message")
        tap(app.buttons["workspace-search-message/\(current)/10000000-0000-0000-0000-000000000021"])
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "ORIGINAL-DRAFT")
        tap(composer)
        composer.typeText("-LOCAL")
        tap(app.buttons["返回对话工作台"])
        app.terminate()
        launch(run: run)
        search("ORIGINAL-DRAFT-LOCAL")
        tap(app.buttons["workspace-search-draft/\(current)"])
        XCTAssertEqual(composer.value as? String, "ORIGINAL-DRAFT-LOCAL")
        capture("Draft restored after process restart")
    }

    func testNativeFailedDraftWriteBlocksNewConversationAndKeepsInput() {
        launch(draftFailure: true)
        tap(app.buttons["home-recent-\(current)"])
        tap(composer)
        composer.typeText("X")
        XCTAssertTrue(app.alerts["操作失败"].waitForExistence(timeout: 10))
        app.alerts.buttons["知道了"].tap()
        let retained = composer.value as? String
        XCTAssertTrue(retained?.contains("X") == true)
        tap(app.buttons["返回对话工作台"])
        tap(app.buttons["home-new-chat"])
        XCTAssertTrue(app.alerts["暂时无法打开"].waitForExistence(timeout: 10))
        capture("Unsaved draft blocks navigation")
        app.alerts.buttons["知道了"].tap()
        tap(app.buttons["home-recent-\(current)"])
        XCTAssertEqual(composer.value as? String, retained)
    }

    private func openBackup() {
        tap(app.tabBars.buttons["设置"])
        tap(app.buttons["备份与恢复"])
    }

    private func visible(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func selectLocalHermesFolder() {
        let browse = app.buttons["Browse"]
        if browse.waitForExistence(timeout: 2) { browse.tap() }
        let local = visible("On My iPhone")
        if local.waitForExistence(timeout: 3) { tap(local) }
        let folder = visible("Hermes")
        if folder.waitForExistence(timeout: 3) { tap(folder) }
    }

    private func importExportedFile() {
        tap(app.buttons["从文件导入备份"])
        selectLocalHermesFolder()
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Hermes-Acceptance")).firstMatch
        tap(file)
        let confirm = app.buttons["确认合并导入"]
        tap(confirm)
        let success = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "恢复完成。")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 15))
        capture("System file import result")
    }

    func testNativeSystemFileExportImportConflictsAndFreshInstallation() {
        launch()
        openBackup()
        tap(app.buttons["导出备份到文件"])
        capture("System export picker")
        selectLocalHermesFolder()
        let name = app.textFields.firstMatch
        tap(name)
        if let value = name.value as? String {
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        name.typeText("Hermes-Acceptance")
        tap(app.buttons["Save"])
        XCTAssertTrue(app.staticTexts["备份已保存。"].waitForExistence(timeout: 15))
        capture("System export saved")
        // Change the local draft after export; importing the older file must keep this edit.
        tap(app.tabBars.buttons["工作台"])
        tap(app.buttons["home-recent-\(current)"])
        tap(composer)
        composer.typeText("-LOCAL")
        tap(app.buttons["返回对话工作台"])
        openBackup()
        importExportedFile()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "保留 4 段已有对话")).firstMatch.exists)
        tap(app.tabBars.buttons["工作台"])
        tap(app.buttons["home-recent-\(current)"])
        XCTAssertEqual(composer.value as? String, "ORIGINAL-DRAFT-LOCAL")
        app.terminate()
        launch(empty: true)
        openBackup()
        importExportedFile()
        app.navigationBars.buttons.firstMatch.tap()
        tap(app.buttons["切换到 Acceptance（已导入）"])
        tap(app.tabBars.buttons["工作台"])
        search("ORIGINAL-DRAFT")
        let draft = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace-search-draft/")).firstMatch
        tap(draft)
        XCTAssertEqual(composer.value as? String, "ORIGINAL-DRAFT")
        XCTAssertTrue(app.buttons["chat-reference-documents"].exists)
        capture("Original draft and project references restored into fresh installation")
    }
}
