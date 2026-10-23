import XCTest
@testable import Hermes

final class MessageLibraryBatchTests: XCTestCase {
    func testOrderingUsesMessageDateThenFullTargetAndIgnoresBookmarkDate() {
        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let first = item(conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, messageID: sharedID,
            date: 10, bookmark: .init(createdAt: Date(timeIntervalSince1970: 100), note: ""))
        let second = item(conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, messageID: sharedID, date: 10)
        let newer = item(date: 20)
        XCTAssertEqual(MessageLibraryBatch.ordered([second, newer, first]).map(\.id), [newer.id, first.id, second.id])
        XCTAssertEqual(MessageLibraryBatch.ordered([first, second, newer]).map(\.id), [newer.id, first.id, second.id])
    }

    func testSameMessageIDInDifferentConversationsIsAValidIndependentTarget() throws {
        let sharedID = UUID()
        let items = [item(messageID: sharedID), item(messageID: sharedID)]
        XCTAssertNotEqual(items[0].id, items[1].id)
        XCTAssertNoThrow(try MessageLibraryBatch.validate(items))
    }

    func testEmptyAndDuplicateTargetsAreRejected() {
        assertError(.empty) { try MessageLibraryBatch.validate([]) }
        let selected = item()
        assertError(.duplicates) { try MessageLibraryBatch.validate([selected, selected]) }
    }

    func testSelectionLimitIsInclusiveAndLargerBatchIsRejected() throws {
        let items = (0..<MessageLibraryBatch.selectionLimit).map { _ in item() }
        XCTAssertNoThrow(try MessageLibraryBatch.validate(items))
        assertError(.selectionLimit) { try MessageLibraryBatch.validate(items + [item()]) }
    }

    func testCharacterCountIncludesCompleteBodyNoteAndSourceMetadataUsingGraphemes() {
        let selected = item(title: "对话👨‍👩‍👧‍👦", content: "正文👩🏽‍💻", bookmark: .init(createdAt: Date(), note: "备注🙂"),
            project: "项目", tags: ["工作", "标签"])
        XCTAssertEqual(MessageLibraryBatch.characterCount([selected]), 3 + 3 + 3 + 2 + 2 + 2)
    }

    func testCharacterLimitIsInclusiveAndNeverTruncatesSelection() throws {
        let content = String(repeating: "字", count: MessageLibraryBatch.characterLimit)
        let boundary = item(title: "", content: content)
        XCTAssertNoThrow(try MessageLibraryBatch.validate([boundary]))
        XCTAssertEqual(boundary.message.content, content)
        assertError(.tooLarge) { try MessageLibraryBatch.validate([item(title: "", content: content + "字")]) }
    }

    func testInvalidMessageAndBookmarkDatesAndMismatchedTargetAreRejected() {
        assertError(.invalid) { try MessageLibraryBatch.validate([item(date: .infinity)]) }
        assertError(.invalid) { try MessageLibraryBatch.validate([item(bookmark: .init(createdAt: Date(timeIntervalSince1970: .nan), note: ""))]) }
        let good = item()
        let bad = MessageLibraryItem(id: .init(conversationID: UUID(), messageID: UUID()), conversationTitle: "测试", message: good.message)
        assertError(.invalid) { try MessageLibraryBatch.validate([bad]) }
    }

    func testAddReportTreatsExistingBookmarksAndTheirNotesAsUnchanged() {
        let items = [item(), item(bookmark: .init(createdAt: Date(), note: "")), item(bookmark: .init(createdAt: Date(), note: "保留备注"))]
        XCTAssertEqual(MessageLibraryBatch.report(items, operation: .add), .init(requested: 3, changed: 1, unchanged: 2, notesRemoved: 0))
    }

    func testRemoveReportCountsOnlyExistingBookmarksAndNonemptyNotes() {
        let items = [item(), item(bookmark: .init(createdAt: Date(), note: "")), item(bookmark: .init(createdAt: Date(), note: "会移除"))]
        XCTAssertEqual(MessageLibraryBatch.report(items, operation: .remove), .init(requested: 3, changed: 2, unchanged: 1, notesRemoved: 1))
        XCTAssertEqual(MessageLibraryBatch.report([], operation: .remove), .init(requested: 0, changed: 0, unchanged: 0, notesRemoved: 0))
    }

    func testMarkdownPreservesCompleteLongUnicodeBodyWithoutQuoteTruncation() throws {
        let body = "  ## 原始 Markdown\n\n" + String(repeating: "👨‍👩‍👧‍👦", count: 5_001) + "\n末尾  \n"
        let markdown = try MessageLibraryBatch.markdown(snapshot([item(content: body)]))
        XCTAssertTrue(markdown.contains("### 正文\n\n" + body))
        XCTAssertFalse(markdown.contains("引用已截取"))
        XCTAssertTrue(markdown.contains("末尾  \n"))
    }

    func testMarkdownIncludesNotesOnlyWhenOptedInAndPreservesTheirWhitespace() throws {
        let note = "  私人备注\n\n- 原样保存 *格式*  \n"
        let value = snapshot([item(bookmark: .init(createdAt: Date(), note: note))])
        let without = try MessageLibraryBatch.markdown(value)
        let withNotes = try MessageLibraryBatch.markdown(value, includeNotes: true)
        XCTAssertFalse(without.contains("私人备注"))
        XCTAssertFalse(without.contains("### 收藏备注"))
        XCTAssertTrue(withNotes.contains("### 收藏备注\n\n" + note))
    }

    func testImageOnlyExportExplainsOmissionWithoutLeakingAttachmentOrTargetIDs() throws {
        let imageID = UUID()
        let selected = item(content: "", imageID: imageID)
        let value = snapshot([selected])
        let markdown = try MessageLibraryBatch.markdown(value)
        XCTAssertTrue(markdown.contains("图片未包含在此汇编中"))
        XCTAssertTrue(markdown.contains("JSON 备份"))
        for id in [imageID, selected.id.conversationID, selected.id.messageID, value.profileID, value.id] {
            XCTAssertFalse(markdown.contains(id.uuidString))
        }
        XCTAssertFalse(markdown.contains("base64"))
    }

    func testMetadataEscapesMarkdownAndNewlinesWithDeterministicUTCDate() throws {
        let selected = item(title: "标题\n# [链接](url) *强调*", content: "正文", date: 0,
            project: "项目|A", tags: ["标签_1", "行\n尾"], archived: true)
        let value = snapshot([selected], name: "连接\n**私有**")
        let markdown = try MessageLibraryBatch.markdown(value)
        XCTAssertTrue(markdown.hasPrefix("# 连接 \\*\\*私有\\*\\* · 消息汇编"))
        XCTAssertTrue(markdown.contains("标题 \\# \\[链接\\]\\(url\\) \\*强调\\*"))
        XCTAssertTrue(markdown.contains("项目：项目\\|A · 标签：标签\\_1、行 尾 · 状态：已归档"))
        XCTAssertTrue(markdown.contains("时间（UTC）：1970-01-01T00:00:00Z"))
        XCTAssertEqual(markdown, try MessageLibraryBatch.markdown(value))
    }

    func testExportRejectsEscapingExpansionOverOneMillionCharactersWithoutTruncation() throws {
        let content = String(repeating: "*", count: MessageLibraryBatch.characterLimit)
        let value = snapshot([item(title: content, content: "")])
        XCTAssertNoThrow(try MessageLibraryBatch.validate(value.items))
        assertError(.tooLarge) { _ = try MessageLibraryBatch.markdown(value) }
        XCTAssertEqual(value.items[0].conversationTitle, content)
    }

    private func snapshot(_ items: [MessageLibraryItem], name: String = "测试连接") -> MessageLibraryBatchSnapshot {
        .init(profileID: UUID(), profileName: name, items: items)
    }

    private func item(conversationID: UUID = UUID(), messageID: UUID = UUID(), title: String = "来源对话", content: String = "完整正文",
                      date: TimeInterval = 1, bookmark: MessageBookmark? = nil, imageID: UUID? = nil,
                      project: String? = nil, tags: [String] = [], archived: Bool = false) -> MessageLibraryItem {
        MessageLibraryItem(id: .init(conversationID: conversationID, messageID: messageID), conversationTitle: title,
            message: ChatMessage(id: messageID, role: .assistant, content: content, createdAt: Date(timeIntervalSince1970: date), imageID: imageID, bookmark: bookmark),
            conversationTags: tags, conversationArchived: archived, projectName: project)
    }

    private func assertError(_ expected: MessageLibraryBatchError, file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
        }
    }
}
