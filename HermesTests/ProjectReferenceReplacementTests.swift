import XCTest
@testable import Hermes

final class ProjectReferenceReplacementTests: XCTestCase {
    private let profileID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let projectID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let date = Date(timeIntervalSince1970: 1_792_600_000)

    func testSourceOnlyBecomesTarget() throws {
        XCTAssertEqual(try replace([id(1)]), [id(2)])
    }

    func testReplacingPreservesOtherReferencesAndSourcePosition() throws {
        XCTAssertEqual(try replace([id(3), id(1), id(4), id(5)]), [id(3), id(2), id(4), id(5)])
    }

    func testExistingEarlierTargetKeepsItsFirstPosition() throws {
        XCTAssertEqual(try replace([id(2), id(3), id(1), id(4)]), [id(2), id(3), id(4)])
    }

    func testExistingLaterTargetMovesToReplacedSourcePosition() throws {
        XCTAssertEqual(try replace([id(3), id(1), id(4), id(2)]), [id(3), id(2), id(4)])
    }

    func testSameDocumentIsRefused() {
        XCTAssertThrowsError(try ProjectReferenceReplacement.replacing([id(1)], sourceID: id(1), targetID: id(1))) {
            guard case ProjectReferenceReplacementError.sameDocument = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testMissingSourceIsNotAnAdditionOperation() {
        for references in [[], [id(2)], [id(3), id(4)]] {
            XCTAssertThrowsError(try replace(references)) {
                guard case ProjectReferenceReplacementError.missingReference = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testRowsSnapshotFullOrderedSelectionsAndStateWithoutMutatingInputs() throws {
        let project = makeProject([document(1), document(2), document(3)])
        for status in ProjectDocumentUsage.Status.allCases {
            var record = conversation([id(3), id(1), id(2)])
            record.workspace = .init(archived: status != .active, trashedAt: status == .trash ? date : nil)
            record.messages = [.init(role: .assistant, content: "历史回复 [资料2]")]
            let original = record
            let row = try makeRow(record, project: project)
            XCTAssertEqual(row.id, record.id)
            XCTAssertEqual(row.title, record.title)
            XCTAssertEqual(row.status, status)
            XCTAssertEqual(row.beforeIDs, [id(3), id(1), id(2)])
            XCTAssertEqual(row.afterIDs, [id(3), id(2)])
            XCTAssertEqual(record, original)
            XCTAssertEqual(project.documents.map(\.id), [id(1), id(2), id(3)])
        }
    }

    func testRowsRequireExactProfileAndProject() {
        let project = makeProject([document(1), document(2)])
        var records = [Conversation]()
        var foreignProfile = conversation([id(1)]); foreignProfile.profileID = UUID(); records.append(foreignProfile)
        var legacyProfile = conversation([id(1)]); legacyProfile.profileID = nil; records.append(legacyProfile)
        var foreignProject = conversation([id(1)]); foreignProject.projectID = UUID(); records.append(foreignProject)
        var unassigned = conversation([id(1)]); unassigned.projectID = nil; records.append(unassigned)
        for record in records {
            XCTAssertThrowsError(try makeRow(record, project: project)) {
                guard case ProjectReferenceReplacementError.changed = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testRowsRequireBothDocumentsInTheSameProject() {
        for documents in [[document(1)], [document(2)], []] {
            XCTAssertThrowsError(try makeRow(conversation([id(1)]), project: makeProject(documents))) {
                guard case ProjectDocumentError.missing = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testMalformedBeforeSelectionsAreRejectedRatherThanRepaired() {
        let project = makeProject((1...7).map { document($0) })
        for references in [[id(1), id(1)], [id(1), id(99)], (1...6).map(id)] {
            XCTAssertThrowsError(try makeRow(conversation(references), project: project))
        }
        var malformed = makeProject([document(1), document(2)])
        malformed.documents[0].body = " "
        XCTAssertThrowsError(try makeRow(conversation([id(1)]), project: malformed))
    }

    func testReplacementAllowsExactlyFiftyThousandCharacters() throws {
        let project = makeProject([document(1), document(2, count: 20_000), document(3, count: 15_000), document(4, count: 15_000)])
        let row = try makeRow(conversation([id(3), id(1), id(4)]), project: project)
        let after = try ProjectDocument.selected(ids: row.afterIDs, from: project)
        XCTAssertEqual(after.reduce(0) { $0 + $1.body.count }, 50_000)
        XCTAssertEqual(row.afterIDs, [id(3), id(2), id(4)])
    }

    func testReplacementRejectsOneCharacterOverBudget() {
        let project = makeProject([document(1), document(2, count: 20_000), document(3, count: 15_000), document(4, count: 15_001)])
        XCTAssertThrowsError(try makeRow(conversation([id(3), id(1), id(4)]), project: project)) {
            guard case ProjectDocumentError.selectionTooLarge = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", number))!
    }
    private func document(_ number: Int, count: Int = 1) -> ProjectDocument {
        .init(id: id(number), title: "资料\(number)", body: String(repeating: "字", count: count), createdAt: date, updatedAt: date)
    }
    private func makeProject(_ documents: [ProjectDocument]) -> LocalProject {
        .init(id: projectID, name: "项目", summary: "", instructions: "", createdAt: date, updatedAt: date,
              knowledgeDocuments: documents)
    }
    private func conversation(_ references: [UUID]) -> Conversation {
        .init(id: id(100), title: "对话", messages: [], updatedAt: date, profileID: profileID,
              projectID: projectID, referenceDocumentIDs: references)
    }
    private func replace(_ references: [UUID]) throws -> [UUID] {
        try ProjectReferenceReplacement.replacing(references, sourceID: id(1), targetID: id(2))
    }
    private func makeRow(_ record: Conversation, project: LocalProject) throws -> ProjectReferenceReplacement.Row {
        try ProjectReferenceReplacement.makeRow(record, sourceID: id(1), targetID: id(2), project: project, profileID: profileID)
    }
}
