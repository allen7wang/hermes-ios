import XCTest
@testable import Hermes

final class ApprovalChoiceTests: XCTestCase {
    func testPathsExtractsSlashAndHomeTokens() {
        let command = "python3 ~/src/run.py --out /tmp/out.txt src/main.swift echo hello"
        XCTAssertEqual(
            ApprovalPathParser.paths(in: command),
            ["~/src/run.py", "/tmp/out.txt", "src/main.swift"]
        )
    }

    func testPathsStripsQuotesPunctuationAndDedupes() {
        let command = "edit \"~/a/b.swift\", 'src/c.swift'; cat ~/a/b.swift (~/notes.md)"
        XCTAssertEqual(
            ApprovalPathParser.paths(in: command),
            ["~/a/b.swift", "src/c.swift", "~/notes.md"]
        )
    }

    func testPathsEmptyWhenCommandHasNoFileTokens() {
        XCTAssertEqual(ApprovalPathParser.paths(in: "echo hello"), [])
        XCTAssertEqual(ApprovalPathParser.paths(in: ""), [])
        XCTAssertEqual(ApprovalPathParser.paths(in: "ls -la"), [])
    }

    func testChoiceButtonsFollowServerChoices() {
        let once = approval(choices: ["once", "deny"])
        XCTAssertTrue(once.allowsOnce)
        XCTAssertFalse(once.allowsSession)
        XCTAssertFalse(once.allowsAlways)

        let session = approval(choices: ["session", "always", "deny"])
        XCTAssertFalse(session.allowsOnce)
        XCTAssertTrue(session.allowsSession)
        XCTAssertTrue(session.allowsAlways)

        let all = approval(choices: ["once", "session", "always", "deny"])
        XCTAssertTrue(all.allowsOnce)
        XCTAssertTrue(all.allowsSession)
        XCTAssertTrue(all.allowsAlways)

        let missing = approval(choices: nil)
        XCTAssertTrue(missing.allowsOnce)
        XCTAssertFalse(missing.allowsSession)
        XCTAssertFalse(missing.allowsAlways)

        let denyOnly = approval(choices: ["deny"])
        XCTAssertFalse(denyOnly.allowsOnce)
        XCTAssertFalse(denyOnly.allowsSession)
        XCTAssertFalse(denyOnly.allowsAlways)
    }

    private func approval(choices: [String]?) -> RemoteApproval {
        RemoteApproval(runID: "run_1", requestID: "req_1", command: nil, description: nil, choices: choices)
    }
}
