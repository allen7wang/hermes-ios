import XCTest
import SwiftUI
import UIKit
@testable import Hermes

final class ProjectReferenceAdditionVisualTests: XCTestCase {
    @MainActor func testAdditionSelectionCompactLayoutDoesNotSelectConversationsOrWrite() async throws {
        let fixture = try AdditionFixture.make(owner: self); let model = fixture.model()
        let files = try fixture.files()
        let view = ProjectReferenceAdditionView(projectID: fixture.projectID, profileID: fixture.profileID,
            initialDocumentIDs: [fixture.doc(2), fixture.doc(1)]).environmentObject(model)
        try await snapshot(view, size: CGSize(width: 390, height: 1200), name: "addition-select-compact")
        XCTAssertEqual(try fixture.files(), files)
        XCTAssertEqual(model.selectedID, fixture.activeID); XCTAssertEqual(model.draft, "尚未发送的草稿")
    }

    @MainActor func testAdditionReviewWideShowsMixedStatesAndNoOpRowsWithoutWriting() async throws {
        let fixture = try AdditionFixture.make(owner: self); let model = fixture.model(); let files = try fixture.files()
        let review = try fixture.review(model, conversations: [fixture.activeID, fixture.trashID, fixture.unchangedID])
        XCTAssertEqual(review.changedCount, 2); XCTAssertEqual(review.rows.count, 3)
        try await snapshot(ProjectReferenceAdditionReviewView(review: review, onApplied: {}).environmentObject(model),
            size: CGSize(width: 1024, height: 1300), name: "addition-review-wide")
        XCTAssertEqual(try fixture.files(), files)
    }

    @MainActor func testAdditionReviewCompactPreservesOrderAndDoesNotWrite() async throws {
        let fixture = try AdditionFixture.make(owner: self); let model = fixture.model(); let files = try fixture.files()
        let review = try fixture.review(model, conversations: [fixture.activeID, fixture.unchangedID])
        XCTAssertEqual(review.changedCount, 1)
        try await snapshot(ProjectReferenceAdditionReviewView(review: review, onApplied: {}).environmentObject(model),
            size: CGSize(width: 390, height: 1500), name: "addition-review-compact")
        XCTAssertEqual(try fixture.files(), files)
    }

    @MainActor private func snapshot<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let controller = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "zh_CN")).preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller; window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(950)); controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData()); XCTAssertGreaterThan(data.count, 1_000)
        XCTAssertEqual(image.size.width, size.width, accuracy: 1); XCTAssertEqual(image.size.height, size.height, accuracy: 1)
        let directory = URL(fileURLWithPath: "/private/tmp/hermes-refadd-20261023-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
