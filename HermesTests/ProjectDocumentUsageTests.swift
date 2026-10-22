import XCTest
@testable import Hermes

final class ProjectDocumentUsageTests: XCTestCase {
    private let profileID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let projectID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let date = Date(timeIntervalSince1970: 1_792_600_000)

    func testReferencesRequireBothProfileAndProjectAndSavedSelection() {
        let document = makeDocument(1)
        let matching = conversation(1, references: [document.id])
        var foreignProfile = conversation(2, references: [document.id]); foreignProfile.profileID = UUID()
        var foreignProject = conversation(3, references: [document.id]); foreignProject.projectID = UUID()
        var legacy = conversation(4, references: [document.id]); legacy.profileID = nil
        var unassigned = conversation(5, references: [document.id]); unassigned.projectID = nil
        let result = references([document.id], [foreignProfile, foreignProject, legacy, unassigned, matching])
        XCTAssertEqual(result.map(\.conversationID), [matching.id])
        XCTAssertEqual(result.first?.slots, [.init(documentID: document.id, number: 1)])
        XCTAssertTrue(references([], [matching]).isEmpty)
    }

    func testMessageTextTitlesAndOldCitationNumbersDoNotCreateReferences() {
        let document = makeDocument(1, title: "独立资料")
        var oldMessage = conversation(1, references: [])
        oldMessage.title = "使用独立资料的旧对话"
        oldMessage.messages = [.init(role: .assistant, content: "[资料1] 独立资料 \(document.id.uuidString)")]
        var absentSelection = oldMessage; absentSelection.id = id(2); absentSelection.referenceDocumentIDs = nil
        XCTAssertTrue(references([document.id], [oldMessage, absentSelection]).isEmpty)
        oldMessage.referenceDocumentIDs = [document.id]
        XCTAssertEqual(references([document.id], [oldMessage]).count, 1)
        oldMessage.referenceDocumentIDs = []
        XCTAssertTrue(references([document.id], [oldMessage]).isEmpty)
    }

    func testReferenceStatesIncludeTrashAndTrashTakesPriorityOverArchive() {
        let document = makeDocument(1)
        let active = conversation(3, references: [document.id])
        let archived = conversation(2, references: [document.id], archived: true)
        let trashed = conversation(1, references: [document.id], archived: true, trashed: true)
        let result = references([document.id], [trashed, archived, active])
        XCTAssertEqual(result.map(\.status), [.active, .archived, .trash])
        XCTAssertEqual(result.map(\.conversationID), [active.id, archived.id, trashed.id])
        XCTAssertEqual(ProjectDocumentUsage.Status.allCases.map(\.title), ["进行中", "已归档", "回收站"])
        XCTAssertEqual(ProjectDocumentUsage.Status.allCases.map(\.order), [0, 1, 2])
    }

    func testReferenceSortUsesStableConversationIDsWithinStatus() {
        let document = makeDocument(1)
        let records = [conversation(8, references: [document.id]), conversation(2, references: [document.id]),
                       conversation(5, references: [document.id], archived: true), conversation(1, references: [document.id], archived: true)]
        let first = references([document.id], records)
        XCTAssertEqual(first.map(\.conversationID), [id(2), id(8), id(1), id(5)])
        XCTAssertEqual(first, references([document.id], Array(records.reversed())))
        XCTAssertEqual(first.map(\.id), first.map(\.conversationID))
    }

    func testSlotsKeepSavedNumbersAndFirstOccurrenceWithoutRenumbering() {
        let first = makeDocument(1); let second = makeDocument(2); let other = makeDocument(3)
        let record = conversation(1, references: [other.id, second.id, first.id, second.id])
        let result = references([first.id, second.id], [record])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.slots, [.init(documentID: second.id, number: 2), .init(documentID: first.id, number: 3)])
        let single = ProjectDocumentUsage.forDocument(first.id, in: result)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first?.slots, [.init(documentID: first.id, number: 3)])
        XCTAssertEqual(single.first?.title, record.title)
        XCTAssertTrue(ProjectDocumentUsage.forDocument(other.id, in: result).isEmpty)
    }

    func testDuplicateInputConversationDoesNotCountTwice() {
        let document = makeDocument(1)
        let record = conversation(1, references: [document.id, document.id])
        let result = references([document.id], [record, record])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.slots.count, 1)
    }

    func testQueryCombinesWithUsageFilterAndSearchesTitleAndBody() {
        let first = makeDocument(1, title: "Café launch", body: "团队结论")
        let second = makeDocument(2, title: "发布", body: "CAFE follow-up")
        let third = makeDocument(3, title: "无关资料", body: "其他内容")
        let docs = [first, second, third]
        let refs = references([first.id], [conversation(1, references: [first.id], trashed: true)])
        XCTAssertEqual(filtered(docs, query: "  cafe\n", references: refs).map(\.id), [first.id, second.id])
        XCTAssertEqual(filtered(docs, query: "cafe", filter: .referenced, references: refs).map(\.id), [first.id])
        XCTAssertEqual(filtered(docs, query: "cafe", filter: .unreferenced, references: refs).map(\.id), [second.id])
        XCTAssertEqual(filtered(docs, query: "结论", references: refs).map(\.id), [first.id])
        XCTAssertTrue(filtered(docs, query: "不存在", references: refs).isEmpty)
        XCTAssertEqual(filtered(docs, query: " \n", filter: .unreferenced, references: refs).map(\.id), [second.id, third.id])
    }

    func testRecentOrderMatchesBatchOrderIncludingTimestampTies() {
        let old = makeDocument(1, offset: -100); let newer = makeDocument(8, offset: 100)
        let tieB = makeDocument(5); let tieA = makeDocument(2)
        let docs = [old, tieB, newer, tieA]
        XCTAssertEqual(filtered(docs).map(\.id), ProjectDocumentBatch.ordered(docs).map(\.id))
        XCTAssertEqual(filtered(docs).map(\.id), [newer.id, tieA.id, tieB.id, old.id])
    }

    func testTitleOrderUsesNaturalComparisonAndRecentFallbackForEqualTitles() {
        let tenth = makeDocument(1, title: "资料10")
        let second = makeDocument(2, title: "资料2", offset: 20)
        let sameOlder = makeDocument(3, title: "资料2", offset: -20)
        let sameTie = makeDocument(4, title: "资料2", offset: -20)
        let result = filtered([tenth, sameTie, sameOlder, second], sort: .title)
        XCTAssertEqual(result.map(\.id), [second.id, sameOlder.id, sameTie.id, tenth.id])
    }

    func testMostReferencedCountsDistinctConversationsAcrossAllStatesAndUsesRecentTies() {
        let first = makeDocument(1, offset: -100); let second = makeDocument(2, offset: 200)
        let third = makeDocument(3, offset: 100); let never = makeDocument(4)
        let records = [conversation(1, references: [first.id, second.id]),
                       conversation(2, references: [first.id], archived: true),
                       conversation(3, references: [first.id, third.id], trashed: true)]
        var refs = references([first.id, second.id, third.id], records)
        // Even a malformed caller-provided reference list cannot inflate a conversation count.
        refs.append(refs[0])
        let result = filtered([never, third, second, first], sort: .mostReferenced, references: refs)
        XCTAssertEqual(result.map(\.id), [first.id, second.id, third.id, never.id])
        XCTAssertEqual(filtered([first, second, third, never], filter: .referenced, sort: .mostReferenced, references: refs).count, 3)
        XCTAssertEqual(filtered([first, second, third, never], filter: .unreferenced, sort: .mostReferenced, references: refs).map(\.id), [never.id])
    }

    func testUsageFilteringDoesNotMutateDocumentsSelectionsOrMessages() {
        let document = makeDocument(1)
        let record = conversation(1, references: [document.id])
        let docs = [document]; let records = [record]
        let refs = references([document.id], records)
        _ = filtered(docs, query: "资料", filter: .referenced, sort: .mostReferenced, references: refs)
        XCTAssertEqual(docs, [document]); XCTAssertEqual(records, [record])
        XCTAssertEqual(refs.first?.slots, [.init(documentID: document.id, number: 1)])
    }

    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", number))!
    }
    private func makeDocument(_ number: Int, title: String = "资料", body: String = "正文", offset: TimeInterval = 0) -> ProjectDocument {
        .init(id: id(number), title: title, body: body, createdAt: date, updatedAt: date.addingTimeInterval(offset))
    }
    private func conversation(_ number: Int, references: [UUID], archived: Bool = false, trashed: Bool = false) -> Conversation {
        .init(id: id(number), title: "讨论\(number)", messages: [], updatedAt: date, profileID: profileID,
              workspace: .init(archived: archived, trashedAt: trashed ? date : nil), projectID: projectID,
              referenceDocumentIDs: references)
    }
    private func references(_ documentIDs: Set<UUID>, _ conversations: [Conversation]) -> [ProjectDocumentUsage.Reference] {
        ProjectDocumentUsage.references(documentIDs: documentIDs, projectID: projectID, profileID: profileID, conversations: conversations)
    }
    private func filtered(_ documents: [ProjectDocument], query: String = "", filter: ProjectDocumentUsageFilter = .all,
                          sort: ProjectDocumentUsageSort = .recent, references: [ProjectDocumentUsage.Reference] = []) -> [ProjectDocument] {
        ProjectDocumentUsage.filtered(documents, query: query, filter: filter, sort: sort, references: references)
    }
}
