import XCTest
@testable import Hermes

final class MessageProjectCaptureTests: XCTestCase {
    func testSuggestedTitleReflectsTheWholeSelectionWithinDocumentTitleLimit() {
        let source = snapshot([item(content: "正文一"), item(content: "正文二"), item(content: "正文三")])
        let title = MessageProjectCaptureText.initialTitle(source)
        XCTAssertEqual(title, "消息汇编 · 3条")
        XCTAssertLessThanOrEqual(title.count, ProjectDocument.titleLimit)
        XCTAssertFalse(title.contains(where: \.isNewline))
    }

    func testBodyRetainsCompleteLongUnicodeTextAndOriginalMarkdownWhitespace() throws {
        let content = "  ## 消息标题\r\n\r\n```swift\nlet text = \"保留格式\"\n```\n"
            + String(repeating: "👨‍👩‍👧‍👦", count: 5_001) + "\n完整末尾  \n"
        let source = snapshot([item(content: content)])
        let body = try MessageProjectCaptureText.initialBody(source)
        XCTAssertTrue(body.contains(content))
        XCTAssertEqual(body.filter { $0 == "👨‍👩‍👧‍👦" }.count, 5_001)
        XCTAssertFalse(body.contains("引用已截取"))
        XCTAssertEqual(body, try MessageLibraryBatch.markdown(source, includeNotes: false))
    }

    func testBodyPreservesCanonicalOrderSourceMetadataAndUTCDate() throws {
        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let first = item(content: "甲正文", title: "同时间甲", date: 0,
            conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, messageID: sharedID)
        let second = item(content: "乙正文", title: "同时间乙", date: 0,
            conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, messageID: sharedID)
        var newer = item(content: "新正文", title: "最新消息", date: 60)
        newer.conversationArchived = true
        newer.projectName = "来源项目"
        newer.conversationTags = ["待整理"]
        let source = snapshot([second, newer, first])
        let body = try MessageProjectCaptureText.initialBody(source)
        XCTAssertTrue(body.contains("## 1. 最新消息"))
        XCTAssertTrue(body.contains("## 2. 同时间甲"))
        XCTAssertTrue(body.contains("## 3. 同时间乙"))
        XCTAssertTrue(body.contains("时间（UTC）：1970-01-01T00:01:00Z"))
        XCTAssertTrue(body.contains("项目：来源项目 · 标签：待整理 · 状态：已归档"))
        XCTAssertTrue(body.contains("角色：Hermes"))
        XCTAssertEqual(source.items.map(\.id), [second.id, newer.id, first.id])
    }

    func testNotesAndAttachmentIdentifiersNeverEnterTheCapturedBody() throws {
        let imageID = UUID()
        let selected = item(content: "保留的正文", imageID: imageID,
            bookmark: .init(createdAt: Date(timeIntervalSince1970: 9), note: "不应进入资料的私人备注"))
        let body = try MessageProjectCaptureText.initialBody(snapshot([selected]))
        XCTAssertTrue(body.contains("保留的正文"))
        XCTAssertTrue(body.contains("图片未包含在此汇编中"))
        XCTAssertFalse(body.contains("不应进入资料的私人备注"))
        XCTAssertFalse(body.contains("### 收藏备注"))
        for id in [imageID, selected.id.conversationID, selected.id.messageID] { XCTAssertFalse(body.contains(id.uuidString)) }
        XCTAssertFalse(body.contains("base64"))
    }

    func testImageOnlyWhitespaceAndNotesOnlySourcesCannotProduceAUsefulCapture() {
        let image = item(content: "", imageID: UUID(), bookmark: .init(createdAt: Date(), note: "只有备注"))
        let whitespace = item(content: " \t\n\r\n\u{3000}")
        for items in [[], [image], [whitespace], [image, whitespace]] {
            assertCaptureError(.noText) { _ = try MessageProjectCaptureText.initialBody(snapshot(items)) }
        }
    }

    func testMixedTextAndImageSourcesRetainBothTextAndExplicitImagePlaceholder() throws {
        let source = snapshot([item(content: "有用的文字", title: "文字来源"), item(content: "", title: "图片来源", imageID: UUID())])
        let body = try MessageProjectCaptureText.initialBody(source)
        XCTAssertTrue(body.contains("有用的文字"))
        XCTAssertTrue(body.contains("图片来源"))
        XCTAssertTrue(body.contains("共 2 条消息"))
        XCTAssertTrue(body.contains("图片未包含在此汇编中"))
    }

    func testPrefillCanExceedDocumentLimitWithoutTruncatingBeforeManualEditing() throws {
        let content = String(repeating: "字", count: ProjectDocument.bodyLimit + 1) + "完整末尾"
        let body = try MessageProjectCaptureText.initialBody(snapshot([item(content: content)]))
        XCTAssertGreaterThan(body.count, ProjectDocument.bodyLimit)
        XCTAssertTrue(body.contains(content))
        XCTAssertThrowsError(try MessageProjectCaptureText.document(title: "需精简", body: body))
        let edited = try MessageProjectCaptureText.document(title: "已经人工精简", body: "手动保留的结论")
        XCTAssertEqual(edited.body, "手动保留的结论")
    }

    func testPrefillLimitIsInclusiveForUnicodeAndOneMoreCharacterIsRejected() throws {
        let overhead = try MessageProjectCaptureText.initialBody(snapshot([item(content: "字")])).count - 1
        let content = String(repeating: "👩🏽‍💻", count: MessageProjectCaptureText.prefillLimit - overhead)
        let source = snapshot([item(content: content)])
        let body = try MessageProjectCaptureText.initialBody(source)
        XCTAssertEqual(body.count, MessageProjectCaptureText.prefillLimit)
        XCTAssertTrue(body.contains(content))
        assertCaptureError(.tooLarge) {
            _ = try MessageProjectCaptureText.initialBody(snapshot([item(content: content + "字")]))
        }
    }

    func testMalformedDuplicateAndOverLimitSelectionsKeepExistingBatchValidation() {
        let selected = item(content: "正文")
        XCTAssertThrowsError(try MessageProjectCaptureText.initialBody(snapshot([selected, selected])))
        let malformed = MessageLibraryItem(id: .init(conversationID: UUID(), messageID: UUID()), conversationTitle: "错误标识", message: selected.message)
        XCTAssertThrowsError(try MessageProjectCaptureText.initialBody(snapshot([malformed])))
        XCTAssertThrowsError(try MessageProjectCaptureText.initialBody(snapshot((0..<101).map { _ in item(content: "正文") })))
    }

    func testEditedDocumentUsesExistingNormalizationAndInclusiveUnicodeBounds() throws {
        let title = String(repeating: "题", count: ProjectDocument.titleLimit)
        let body = String(repeating: "👨‍👩‍👧‍👦", count: ProjectDocument.bodyLimit)
        let document = try MessageProjectCaptureText.document(title: " \n" + title + "\t ", body: " \n" + body + "\n ")
        XCTAssertEqual(document.title, title)
        XCTAssertEqual(document.body, body)
        XCTAssertEqual(try document.validated(), document)
        XCTAssertThrowsError(try MessageProjectCaptureText.document(title: title + "题", body: "正文"))
        XCTAssertThrowsError(try MessageProjectCaptureText.document(title: "标题", body: body + "字"))
        XCTAssertThrowsError(try MessageProjectCaptureText.document(title: "标题\n换行", body: "正文"))
        XCTAssertThrowsError(try MessageProjectCaptureText.document(title: " \n", body: "正文"))
        XCTAssertThrowsError(try MessageProjectCaptureText.document(title: "标题", body: " \n"))
    }

    func testCapacityAllowsTheTwentiethDocumentButRejectsTheTwentyFirst() throws {
        let document = try MessageProjectCaptureText.document(title: "新增", body: "正文")
        let existing = (0..<19).map { _ in ProjectDocument(title: "已有", body: "正文") }
        XCTAssertNoThrow(try MessageProjectCaptureText.validateCapacity(document, in: project(existing)))
        XCTAssertThrowsError(try MessageProjectCaptureText.validateCapacity(document, in: project(existing + [ProjectDocument(title: "第二十篇", body: "正文")])))
    }

    func testCapacityAllowsExactlyTwoHundredThousandCharactersAndRejectsOneMore() throws {
        let existing = (0..<9).map { _ in ProjectDocument(title: "已有", body: String(repeating: "字", count: 20_000)) }
        let boundary = try MessageProjectCaptureText.document(title: "新增", body: String(repeating: "字", count: 20_000))
        XCTAssertNoThrow(try MessageProjectCaptureText.validateCapacity(boundary, in: project(existing)))
        XCTAssertThrowsError(try MessageProjectCaptureText.validateCapacity(boundary, in: project(existing + [ProjectDocument(title: "额外", body: "字")])))
    }

    func testCapacityChecksNormalizedNewContentAndRejectsDuplicateIDsOrInvalidExistingDocuments() throws {
        let existing = ProjectDocument(title: "已有", body: "正文")
        XCTAssertThrowsError(try MessageProjectCaptureText.validateCapacity(existing, in: project([existing])))
        let invalid = ProjectDocument(title: "标题", body: " \n")
        let document = ProjectDocument(title: "  新标题  ", body: "  新正文\n")
        XCTAssertNoThrow(try MessageProjectCaptureText.validateCapacity(document, in: project([])))
        XCTAssertThrowsError(try MessageProjectCaptureText.validateCapacity(document, in: project([invalid])))
        XCTAssertEqual(document.title, "  新标题  ")
        XCTAssertEqual(document.body, "  新正文\n")
    }

    private func snapshot(_ items: [MessageLibraryItem]) -> MessageLibraryBatchSnapshot {
        .init(profileID: UUID(), profileName: "采集测试连接", items: items)
    }

    private func item(content: String, title: String = "来源对话", date: TimeInterval = 1,
                      imageID: UUID? = nil, bookmark: MessageBookmark? = nil,
                      conversationID: UUID = UUID(), messageID: UUID = UUID()) -> MessageLibraryItem {
        MessageLibraryItem(id: .init(conversationID: conversationID, messageID: messageID), conversationTitle: title,
            message: ChatMessage(id: messageID, role: .assistant, content: content, createdAt: Date(timeIntervalSince1970: date), imageID: imageID, bookmark: bookmark))
    }

    private func project(_ documents: [ProjectDocument]) -> LocalProject {
        var project = LocalProject(name: "目标项目", summary: "", instructions: "")
        project.documents = documents
        return project
    }

    private func assertCaptureError(_ expected: MessageProjectCaptureError, file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
        }
    }
}
