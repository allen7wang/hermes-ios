import XCTest
@testable import Hermes

final class MessageContentTests: XCTestCase {
    func testCodeCopyPayloadPreservesWhitespaceUnicodeAndTrailingNewline() {
        let result = MessageContent.blocks("说明\n```swift\n  let 名称 = \"Hermes\"\n\n```\n结束")
        XCTAssertEqual(result.map(\.kind), [.prose("说明\n"), .code(language: "swift", text: "  let 名称 = \"Hermes\"\n\n"), .prose("结束")])
        XCTAssertEqual(result.map(\.id), [0, 1, 2])
    }

    func testTildeFencesAcceptLanguageInfoAndCRLFWithoutAlteringCode() {
        let result = MessageContent.blocks("~~~python title=demo\r\nprint('你好')\r\n~~~\r\n")
        XCTAssertEqual(result.first?.kind, .code(language: "python", text: "print('你好')\r\n"))
    }

    func testLongFencesRequireMatchingMarkerAndAtLeastOpeningLength() {
        let result = MessageContent.blocks("````text\n```\n~~~\n```` trailing\n`````\n")
        XCTAssertEqual(result.first?.kind, .code(language: "text", text: "```\n~~~\n```` trailing\n"))
    }

    func testIncompleteStreamingFenceRetainsRawCodeUntilItCloses() {
        XCTAssertEqual(MessageContent.blocks("```js\nconst a = 1").first?.kind, .code(language: "js", text: "const a = 1"))
        XCTAssertEqual(MessageContent.blocks("```\n").first?.kind, .code(language: nil, text: ""))
        XCTAssertEqual(MessageContent.blocks("```\nx\n```\n~~~\ny\n~~~").map(\.kind), [.code(language: nil, text: "x\n"), .code(language: nil, text: "y\n")])
    }

    func testInlineShortIndentedAndInvalidFencesStayProse() {
        for text in ["inline ```swift", "``\nx\n``", "    ```swift\nx", "```bad`info\nx"] {
            XCTAssertEqual(MessageContent.blocks(text).map(\.kind), [.prose(text)])
        }
    }

    func testSearchMatchesChineseCaseAndDiacriticsInSourceText() {
        let entries = [MessageSearchEntry(id: "a", label: "Hermes", text: "发布 Café HERMES 中文版本"),
                       MessageSearchEntry(id: "b", label: "我", text: "另一个问题")]
        XCTAssertEqual(MessageSearch.hits(in: entries, query: " cafe ").first?.match, "Café")
        XCTAssertEqual(MessageSearch.hits(in: entries, query: "hermes").map(\.id), ["a"])
        XCTAssertEqual(MessageSearch.hits(in: entries, query: "中文").first?.match, "中文")
    }

    func testSearchSnippetCentersLateMatchWithoutBreakingEmojiOrAccents() throws {
        let prefix = String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 100)
        let suffix = String(repeating: "中文", count: 100)
        let entry = MessageSearchEntry(id: "deep", label: "Hermes", text: prefix + "目标" + suffix)
        let hit = try XCTUnwrap(MessageSearch.hits(in: [entry], query: "目标").first)
        XCTAssertEqual(hit.match, "目标")
        XCTAssertTrue(hit.before.hasPrefix("…"))
        XCTAssertTrue(hit.after.hasSuffix("…"))
        XCTAssertEqual(hit.before.count, 49)
        XCTAssertEqual(hit.after.count, 81)
        XCTAssertEqual(hit.before.dropFirst(), prefix.suffix(48))
    }

    func testSearchHasNoResultsForEmptyQueryAndOnlySearchesSuppliedScope() {
        let entries = [MessageSearchEntry(id: "loaded", label: "Hermes", text: "当前记录"),
                       MessageSearchEntry(id: "image", label: "我", text: "")]
        XCTAssertTrue(MessageSearch.hits(in: entries, query: " \n ").isEmpty)
        XCTAssertTrue(MessageSearch.hits(in: entries, query: "未加载的消息").isEmpty)
        XCTAssertEqual(MessageSearch.hits(in: entries, query: "记录").map(\.id), ["loaded"])
    }
}
