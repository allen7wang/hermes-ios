import XCTest
@testable import Hermes

final class InboxStoreTests: XCTestCase {
    private var directory: URL!
    private var originalStorageURL: URL!
    private let profileID = UUID()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        originalStorageURL = InboxStore.storageURL
        InboxStore.storageURL = directory.appendingPathComponent("inbox-items.json")
    }

    override func tearDown() {
        InboxStore.storageURL = originalStorageURL
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testUpsertSortsNewestFirstAndReplacesSameID() throws {
        let older = item(id: "older", title: "旧事项", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = item(id: "newer", title: "新事项", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        try InboxStore.upsert(older)
        try InboxStore.upsert(newer)
        XCTAssertEqual(try InboxStore.items(profileID: profileID).map(\.id), ["newer", "older"])

        let promoted = item(id: "older", title: "已更新", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        try InboxStore.upsert(promoted)
        XCTAssertEqual(try InboxStore.items(profileID: profileID).map(\.id), ["older", "newer"])
        XCTAssertEqual(try InboxStore.items(profileID: profileID).first?.title, "已更新")
        XCTAssertEqual(try InboxStore.items(profileID: profileID).count, 2)
    }

    func testRemoveAndPersistAcrossANewRead() throws {
        let kept = item(id: "keep", title: "留下", createdAt: Date(timeIntervalSince1970: 1_700_000_050))
        let dropped = item(id: "drop", title: "删掉", createdAt: Date(timeIntervalSince1970: 1_700_000_080))
        try InboxStore.upsert(kept)
        try InboxStore.upsert(dropped)
        try InboxStore.remove(id: "drop", profileID: profileID)
        try InboxStore.remove(id: "missing", profileID: profileID)

        let url = InboxStore.storageURL
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("留下"))
        XCTAssertFalse(raw.contains("删掉"))

        InboxStore.storageURL = url
        let reread = try InboxStore.items(profileID: profileID)
        XCTAssertEqual(reread, [kept])
        XCTAssertEqual(InboxStore.didChange.rawValue, "HermesInboxDidChange")
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testSameIDOnAnotherProfileRemainsIsolated() throws {
        let otherProfileID = UUID()
        let first = item(id: "same", title: "本连接", createdAt: Date())
        var other = first
        other.profileID = otherProfileID
        other.title = "另一连接"
        try InboxStore.upsert(first)
        try InboxStore.upsert(other)

        XCTAssertEqual(try InboxStore.items(profileID: profileID), [first])
        XCTAssertEqual(try InboxStore.items(profileID: otherProfileID), [other])
        try InboxStore.removeAll(profileID: profileID)
        XCTAssertTrue(try InboxStore.items(profileID: profileID).isEmpty)
        XCTAssertEqual(try InboxStore.items(profileID: otherProfileID), [other])
        XCTAssertEqual(try InboxStore.items(profileID: otherProfileID).first?.choices, ["session", "deny"])
        XCTAssertEqual(try InboxStore.items(profileID: otherProfileID).first?.command, "cat ~/notes.txt")
    }

    func testCorruptFileIsNotOverwritten() throws {
        let url = InboxStore.storageURL
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)

        XCTAssertThrowsError(try InboxStore.items(profileID: profileID))
        XCTAssertThrowsError(try InboxStore.upsert(item(id: "new", title: "新事项", createdAt: Date())))
        XCTAssertThrowsError(try InboxStore.removeAll(profileID: profileID))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    private func item(id: String, title: String, createdAt: Date) -> InboxItem {
        InboxItem(id: id, profileID: profileID, sessionID: "session-\(id)", sessionTitle: "会话",
            runID: "run-\(id)", requestID: "request-\(id)", command: "cat ~/notes.txt",
            choices: ["session", "deny"],
            kind: .approval, title: title,
            detail: "详情", createdAt: createdAt)
    }
}
