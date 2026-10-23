import XCTest
@testable import Hermes

final class MessageDraftQuoteTests: XCTestCase {
    func testReferenceRoundTripsTheCompleteMarkdownIncludingBlankAndCRLFLines() throws {
        let body = "  # 原始标题\r\n\r\n> 原有引用\n\n```swift\nlet value = 1\n```\n尾部  \n"
        let source = snapshot([item(content: body)])
        let reference = try MessageDraftQuote.referenceText(source)
        let lines = reference.components(separatedBy: "\n")
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("> ") })
        let recovered = lines.map { String($0.dropFirst(2)) }.joined(separator: "\n")
        XCTAssertEqual(recovered, try MessageLibraryBatch.markdown(source, includeNotes: false))
        XCTAssertTrue(recovered.contains(body))
        XCTAssertTrue(reference.contains("> > 原有引用"))
        XCTAssertTrue(reference.contains("> ```swift\n> let value = 1\n> ```"))
    }

    func testReferenceNeverIncludesBookmarkNotesOrAttachmentIdentifiers() throws {
        let imageID = UUID()
        let selected = item(content: "图片的说明", imageID: imageID,
            bookmark: .init(createdAt: Date(timeIntervalSince1970: 9), note: "只属于收藏的私人备注"))
        let source = snapshot([selected])
        let reference = try MessageDraftQuote.referenceText(source)
        XCTAssertTrue(reference.contains("图片的说明"))
        XCTAssertTrue(reference.contains("图片未包含在此汇编中"))
        XCTAssertFalse(reference.contains("只属于收藏的私人备注"))
        XCTAssertFalse(reference.contains("### 收藏备注"))
        XCTAssertFalse(reference.contains(imageID.uuidString))
        XCTAssertFalse(reference.contains(selected.id.messageID.uuidString))
        XCTAssertFalse(reference.contains(selected.id.conversationID.uuidString))
        XCTAssertFalse(reference.contains("base64"))
    }

    func testImageOnlyMessageProducesAnExplicitTextPlaceholder() throws {
        let reference = try MessageDraftQuote.referenceText(snapshot([item(content: "", imageID: UUID())]))
        XCTAssertTrue(reference.contains("> ### 正文"))
        XCTAssertTrue(reference.contains("图片未包含在此汇编中"))
        XCTAssertTrue(reference.contains("JSON 备份"))
    }

    func testReferenceOrderUsesMessageTimeAndStableCompositeTargetWithoutMutatingInput() throws {
        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let first = item(title: "同时间甲", content: "甲正文", date: 10,
            conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, messageID: sharedID)
        let second = item(title: "同时间乙", content: "乙正文", date: 10,
            conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, messageID: sharedID)
        let newer = item(title: "最新消息", content: "新正文", date: 20)
        let source = snapshot([second, newer, first])
        let reference = try MessageDraftQuote.referenceText(source)
        XCTAssertTrue(reference.contains("> ## 1. 最新消息"))
        XCTAssertTrue(reference.contains("> ## 2. 同时间甲"))
        XCTAssertTrue(reference.contains("> ## 3. 同时间乙"))
        XCTAssertEqual(source.items.map(\.id), [second.id, newer.id, first.id])
        XCTAssertEqual(reference, try MessageDraftQuote.referenceText(snapshot([first, second, newer])))
    }

    func testReferenceIncludesMoreThanFourThousandUnicodeCharactersWithoutTruncation() throws {
        let body = String(repeating: "👨‍👩‍👧‍👦", count: 5_001) + "完整末尾"
        let reference = try MessageDraftQuote.referenceText(snapshot([item(content: body)]))
        XCTAssertTrue(reference.contains("> " + body))
        XCTAssertFalse(reference.contains("引用已截取"))
        XCTAssertEqual(reference.filter { $0 == "👨‍👩‍👧‍👦" }.count, 5_001)
    }

    func testReferenceLimitIncludesAddedQuoteMarkersAtTheExactUnicodeBoundary() throws {
        let base = snapshot([item(content: "")])
        let overhead = try MessageDraftQuote.referenceText(base).count
        let body = String(repeating: "👩🏽‍💻", count: MessageDraftQuote.draftLimit - overhead)
        let boundary = snapshot([item(content: body)])
        XCTAssertEqual(try MessageDraftQuote.referenceText(boundary).count, MessageDraftQuote.draftLimit)
        assertQuoteError(.draftTooLong) {
            _ = try MessageDraftQuote.referenceText(snapshot([item(content: body + "字")]))
        }
    }

    func testManyShortLinesRejectQuoteExpansionRatherThanSilentlyCuttingTheBody() throws {
        let body = String(repeating: "字\n", count: 25_000)
        let source = snapshot([item(content: body)])
        XCTAssertLessThan(try MessageLibraryBatch.markdown(source).count, MessageDraftQuote.draftLimit)
        assertQuoteError(.draftTooLong) { _ = try MessageDraftQuote.referenceText(source) }
        XCTAssertEqual(source.items[0].message.content, body)
    }

    func testInvalidEmptyDuplicateAndMalformedSourcesCannotBecomeReferences() {
        XCTAssertThrowsError(try MessageDraftQuote.referenceText(snapshot([])))
        let selected = item(content: "正文")
        XCTAssertThrowsError(try MessageDraftQuote.referenceText(snapshot([selected, selected])))
        let malformed = MessageLibraryItem(id: .init(conversationID: UUID(), messageID: UUID()),
            conversationTitle: "错误标识", message: selected.message)
        XCTAssertThrowsError(try MessageDraftQuote.referenceText(snapshot([malformed])))
    }

    func testAppendPreservesBothExistingAndReferenceWhitespaceWithOneSeparator() throws {
        let current = "  先回答这个问题\n\n"
        let reference = "\n> 引用正文  \n"
        XCTAssertEqual(try MessageDraftQuote.draft(current: current, reference: reference, mode: .append),
            "  先回答这个问题\n\n\n\n\n> 引用正文  \n")
        XCTAssertEqual(try MessageDraftQuote.draft(current: "", reference: reference, mode: .append), reference)
    }

    func testReplaceRetainsReferenceExactlyAndDoesNotLimitTheDiscardedOldDraft() throws {
        let oldDraft = String(repeating: "字", count: MessageDraftQuote.draftLimit + 1)
        let reference = "  > 新的引用\n\n"
        XCTAssertEqual(try MessageDraftQuote.draft(current: oldDraft, reference: reference, mode: .replace), reference)
        assertQuoteError(.draftTooLong) {
            _ = try MessageDraftQuote.draft(current: oldDraft, reference: reference, mode: .append)
        }
    }

    func testWhitespaceOnlyReferencesAreRejectedWithoutReplacingTheExistingDraft() {
        for mode in PromptDraftMode.allCases {
            for reference in ["", " \t\n\r\n", "\u{3000}"] {
                assertQuoteError(.invalid) { _ = try MessageDraftQuote.draft(current: "必须保留", reference: reference, mode: mode) }
            }
        }
    }

    func testDraftLimitCountsWholeUnicodeGraphemesAndIncludesAppendSeparator() throws {
        let reference = String(repeating: "👨‍👩‍👧‍👦", count: MessageDraftQuote.draftLimit)
        XCTAssertEqual(try MessageDraftQuote.draft(current: "", reference: reference, mode: .append), reference)
        XCTAssertEqual(try MessageDraftQuote.draft(current: "旧草稿", reference: reference, mode: .replace), reference)
        let tail = String(reference.prefix(MessageDraftQuote.draftLimit - 3))
        XCTAssertEqual(try MessageDraftQuote.draft(current: "首", reference: tail, mode: .append).count, MessageDraftQuote.draftLimit)
        assertQuoteError(.draftTooLong) {
            _ = try MessageDraftQuote.draft(current: "首字", reference: tail, mode: .append)
        }
        assertQuoteError(.draftTooLong) {
            _ = try MessageDraftQuote.draft(current: "", reference: reference + "字", mode: .replace)
        }
    }

    private func snapshot(_ items: [MessageLibraryItem]) -> MessageLibraryBatchSnapshot {
        .init(profileID: UUID(), profileName: "引用测试连接", items: items)
    }

    private func item(title: String = "来源对话", content: String, date: TimeInterval = 1,
                      imageID: UUID? = nil, bookmark: MessageBookmark? = nil,
                      conversationID: UUID = UUID(), messageID: UUID = UUID()) -> MessageLibraryItem {
        MessageLibraryItem(id: .init(conversationID: conversationID, messageID: messageID), conversationTitle: title,
            message: ChatMessage(id: messageID, role: .assistant, content: content, createdAt: Date(timeIntervalSince1970: date),
                imageID: imageID, bookmark: bookmark), conversationTags: ["整理"], projectName: "引用项目")
    }

    private func assertQuoteError(_ expected: MessageDraftQuoteError, file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
        }
    }
}
