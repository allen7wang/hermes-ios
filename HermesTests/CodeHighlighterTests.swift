import XCTest
@testable import Hermes

final class CodeHighlighterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CodeHighlighter.resetCacheForTesting()
    }

    func testHighlightsKnownLanguage() throws {
        let code = "let answer = 42\nprint(answer)\n"
        let result = try XCTUnwrap(CodeHighlighter.highlighted(code: code, language: "swift"))
        XCTAssertEqual(
            String(result.characters).trimmingCharacters(in: .whitespacesAndNewlines),
            code.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(Self.hasForegroundColor(result), "highlighted code should carry token colors")
    }

    func testReturnsNilForUnknownLanguage() {
        XCTAssertNil(CodeHighlighter.highlighted(code: "let x = 1", language: "definitelynotalanguage"))
    }

    func testReturnsNilForPlainTextLanguage() {
        XCTAssertNil(CodeHighlighter.highlighted(code: "just words", language: "plaintext"))
        XCTAssertNil(CodeHighlighter.highlighted(code: "just words", language: "txt"))
    }

    func testCanonicalLanguageResolution() {
        let supported: Set<String> = ["bash", "python", "cpp", "csharp", "xml", "plaintext", "swift"]
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("sh", supported: supported), "bash")
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("PY", supported: supported), "python")
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("c++", supported: supported), "cpp")
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("c#", supported: supported), "csharp")
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("html", supported: supported), "xml")
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("  Swift ", supported: supported), "swift")
        XCTAssertNil(CodeHighlighter.canonicalLanguage("plaintext", supported: supported))
        XCTAssertNil(CodeHighlighter.canonicalLanguage("txt", supported: supported))
        XCTAssertNil(CodeHighlighter.canonicalLanguage("nope", supported: supported))
        XCTAssertNil(CodeHighlighter.canonicalLanguage("", supported: supported))
    }

    func testReturnsNilWhenLanguageMissing() {
        XCTAssertNil(CodeHighlighter.highlighted(code: "let x = 1", language: nil))
        XCTAssertNil(CodeHighlighter.highlighted(code: "let x = 1", language: "   "))
    }

    func testSupportsCommonAlias() {
        XCTAssertNotNil(CodeHighlighter.highlighted(code: "echo hi\n", language: "sh"))
        XCTAssertNotNil(CodeHighlighter.highlighted(code: "x = 1\n", language: "py"))
    }

    func testNormalizesLanguageCase() {
        XCTAssertNotNil(CodeHighlighter.highlighted(code: "let x = 1", language: "Swift"))
    }

    func testSkipsOversizedCode() {
        let huge = String(repeating: "let x = 1\n", count: CodeHighlighter.maximumCodeLength)
        XCTAssertNil(CodeHighlighter.highlighted(code: huge, language: "swift"))
    }

    func testSkipsEmptyCode() {
        XCTAssertNil(CodeHighlighter.highlighted(code: "", language: "swift"))
    }

    func testStripsThemeBackgroundAndFont() throws {
        let result = try XCTUnwrap(CodeHighlighter.highlighted(code: "def f():\n    return 1\n", language: "python"))
        let attributed = NSAttributedString(result)
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.backgroundColor], "card provides its own background")
            XCTAssertNil(attributes[.font], "card provides its own monospaced font")
        }
    }

    func testCacheReturnsEquivalentResult() throws {
        let code = "SELECT * FROM t;"
        let first = try XCTUnwrap(CodeHighlighter.highlighted(code: code, language: "sql"))
        let second = try XCTUnwrap(CodeHighlighter.highlighted(code: code, language: "sql"))
        XCTAssertEqual(first, second)
    }

    private static func hasForegroundColor(_ attributed: AttributedString) -> Bool {
        let attributed = NSAttributedString(attributed)
        var found = false
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, stop in
            if attributes[.foregroundColor] != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
