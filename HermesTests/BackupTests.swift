import XCTest
import UIKit
@testable import Hermes

final class BackupTests: XCTestCase {
    @MainActor
    func testBackupRoundTripIncludesImagesDraftsAndPinsButNeverConnectionKeys() throws {
        let source = try makeSource()
        let archive = try source.model.makeBackup()
        let data = try archive.encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("source-secret"))
        let decoded = try BackupArchive.decode(data)
        XCTAssertEqual(decoded.profiles.count, 1)
        XCTAssertEqual(decoded.conversations.count, 2)
        XCTAssertEqual(decoded.drafts.count, 3)
        XCTAssertEqual(decoded.images.values.first, source.image)
        XCTAssertTrue(decoded.conversations.contains { $0.isPinned })
        XCTAssertEqual(decoded.conversations.first?.profileID, ConnectionProfile.legacyID)
    }

    @MainActor
    func testImportIntoAnotherInstallationRemapsProfilesAndRestoresImagesWithoutKeys() throws {
        let source = try makeSource()
        let destination = try makeFixture()
        destination.keys.values["api-server-key"] = "destination-secret"
        let model = destination.model()
        let originalProfile = model.activeProfileID
        let report = try model.importBackup(source.model.makeBackup())
        XCTAssertEqual(report.profilesAdded, 1)
        XCTAssertEqual(report.conversationsAdded, 2)
        XCTAssertEqual(report.draftsAdded, 3)
        XCTAssertEqual(report.imagesAdded, 1)
        XCTAssertEqual(model.activeProfileID, originalProfile)
        XCTAssertTrue(model.conversations.isEmpty)
        let imported = try XCTUnwrap(model.profiles.first { $0.id != originalProfile })
        XCTAssertNotEqual(imported.id, ConnectionProfile.legacyID)
        XCTAssertTrue(imported.name.hasSuffix("（已导入）"))
        model.selectProfile(imported.id)
        XCTAssertEqual(model.settings.apiKey, "")
        XCTAssertFalse(model.settings.isConfigured)
        XCTAssertEqual(model.conversations.count, 2)
        XCTAssertEqual(model.draft, "会话草稿")
        let importedImageID = try XCTUnwrap(model.conversations.flatMap(\.messages).compactMap(\.imageID).first)
        XCTAssertEqual(try ImageAttachmentStore.load(importedImageID, directory: model.attachmentDirectory), source.image)
        let remoteKey = DraftStore.remoteKey(settings: model.settings, sessionID: "api_example")
        XCTAssertEqual(model.draftStore.text(for: remoteKey), "远端草稿")
        let reopened = destination.model()
        XCTAssertEqual(reopened.conversations.count, 2)
        XCTAssertEqual(reopened.draft, "会话草稿")
        XCTAssertEqual(destination.keys.values, ["api-server-key": "destination-secret"])
    }

    @MainActor
    func testRepeatedImportPreservesCurrentRecordsAndDraftsWithoutDuplicates() throws {
        let source = try makeSource()
        let destination = try makeFixture()
        let model = destination.model()
        let archive = try source.model.makeBackup()
        _ = try model.importBackup(archive)
        let imported = try XCTUnwrap(model.profiles.first { $0.id != model.activeProfileID })
        model.selectProfile(imported.id)
        let selected = try XCTUnwrap(model.selectedID)
        model.rename(selected, to: "本机已修改标题")
        model.draft = "本机新草稿"
        let before = model.conversations
        let preview = try model.previewImport(archive)
        XCTAssertEqual(preview.conversationsAdded, 0)
        XCTAssertEqual(model.conversations, before)
        let second = try model.importBackup(archive)
        XCTAssertEqual(second.profilesAdded, 0)
        XCTAssertEqual(second.conversationsAdded, 0)
        XCTAssertEqual(second.conversationsKept, 2)
        XCTAssertEqual(second.imagesAdded, 0)
        XCTAssertEqual(second.draftsAdded, 0)
        XCTAssertEqual(model.draft, "本机新草稿")
        XCTAssertEqual(model.conversations, before)
        XCTAssertEqual(try model.makeBackup().images.count, 1)
    }

    @MainActor
    func testSameInstallationRestoreDoesNotAttachHistoryToChangedEndpoint() throws {
        let source = try makeSource()
        var archive = try source.model.makeBackup()
        archive.profiles[0].serverURL = "https://different.test/v1"
        let beforeKeys = source.fixture.keys.values
        let report = try source.model.importBackup(archive)
        XCTAssertEqual(report.profilesAdded, 1)
        XCTAssertEqual(report.conversationsAdded, 2)
        XCTAssertEqual(source.model.conversations.count, 2)
        XCTAssertEqual(source.model.settings.serverURL, "https://source.test/v1")
        let imported = try XCTUnwrap(source.model.profiles.first { $0.id != source.model.activeProfileID })
        source.model.selectProfile(imported.id)
        XCTAssertEqual(source.model.settings.apiKey, "")
        XCTAssertEqual(source.model.settings.serverURL, "https://different.test/v1")
        XCTAssertEqual(source.fixture.keys.values, beforeKeys)
    }

    @MainActor
    func testInvalidArchivesAreRejectedBeforeAnyDestinationChanges() throws {
        let source = try makeSource()
        let archive = try source.model.makeBackup()
        let destination = try makeFixture()
        let model = destination.model()
        var variants: [BackupArchive] = []
        var unsupported = archive; unsupported.version = 99; variants.append(unsupported)
        var missingImage = archive; missingImage.images = [:]; variants.append(missingImage)
        var duplicate = archive; duplicate.conversations.append(duplicate.conversations[0]); variants.append(duplicate)
        var orphan = archive; orphan.conversations[0].profileID = UUID(); variants.append(orphan)
        var draft = archive; draft.drafts = ["../local/new": "异常草稿"]; variants.append(draft)
        var image = archive; image.images = image.images.mapValues { _ in Data("invalid-image".utf8) }; variants.append(image)
        for variant in variants { XCTAssertThrowsError(try model.importBackup(variant)) }
        XCTAssertThrowsError(try BackupArchive.decode(Data("{}".utf8)))
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(destination.keys.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.directory.appendingPathComponent("pending-restore.json").path))
    }

    @MainActor
    func testInterruptedImportJournalCompletesOnNextLaunch() throws {
        let source = try makeSource()
        let destination = try makeFixture()
        let model = destination.model()
        let draftURL = destination.directory.appendingPathComponent("drafts.json")
        if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
        try FileManager.default.createDirectory(at: draftURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try model.importBackup(source.model.makeBackup()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.directory.appendingPathComponent("pending-restore.json").path))
        try FileManager.default.removeItem(at: draftURL)
        let reopened = destination.model()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.profiles.count, 2)
        let imported = try XCTUnwrap(reopened.profiles.first { $0.id != reopened.activeProfileID })
        reopened.selectProfile(imported.id)
        XCTAssertEqual(reopened.conversations.count, 2)
        XCTAssertEqual(reopened.draft, "会话草稿")
        XCTAssertEqual(try reopened.makeBackup().images.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.directory.appendingPathComponent("pending-restore.json").path))
    }

    @MainActor
    func testRecoveryPreservesUnreadableFilesBeforeRestoringBackup() throws {
        let source = try makeSource()
        let destination = try makeFixture()
        let original = Data("unreadable conversations".utf8)
        try original.write(to: destination.directory.appendingPathComponent("conversations.json"))
        destination.keys.values["api-server-key"] = "keep-this-key"
        let model = destination.model()
        XCTAssertTrue(model.needsRecovery)
        let report = try model.previewImport(source.model.makeBackup())
        XCTAssertEqual(report.conversationsAdded, 2)
        XCTAssertEqual(try Data(contentsOf: destination.directory.appendingPathComponent("conversations.json")), original)
        _ = try model.importBackup(source.model.makeBackup())
        XCTAssertFalse(model.needsRecovery)
        let copies = try FileManager.default.contentsOfDirectory(at: destination.directory.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: copies[0].appendingPathComponent("conversations.json")), original)
        XCTAssertEqual(destination.keys.values, ["api-server-key": "keep-this-key"])
        let imported = try XCTUnwrap(model.profiles.first { $0.id != model.activeProfileID })
        model.selectProfile(imported.id)
        XCTAssertEqual(model.conversations.count, 2)
        XCTAssertEqual(try model.makeBackup().images.count, 1)
        XCTAssertNil(destination.model().errorMessage)
    }

    @MainActor
    func testDeletingImportedConversationKeepsImagesSharedByOtherRecords() throws {
        let source = try makeSource()
        var archive = try source.model.makeBackup()
        let sharedID = try XCTUnwrap(archive.conversations[0].messages.first?.imageID)
        archive.conversations[1].messages = [ChatMessage(role: .user, content: "同一张图片", imageID: sharedID)]
        let destination = try makeFixture()
        let model = destination.model()
        _ = try model.importBackup(archive)
        model.selectProfile(try XCTUnwrap(model.profiles.first { $0.id != model.activeProfileID }).id)
        let id = try XCTUnwrap(model.conversations.flatMap(\.messages).compactMap(\.imageID).first)
        model.delete(model.conversations[0].id)
        XCTAssertEqual(try ImageAttachmentStore.load(id, directory: model.attachmentDirectory), source.image)
        XCTAssertEqual(try model.makeBackup().images.count, 1)
        model.delete(model.conversations[0].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAttachmentStore.fileURL(for: id, directory: model.attachmentDirectory).path))
    }

    @MainActor
    func testPinsPersistAndRemainScopedToCurrentConnection() throws {
        let fixture = try makeFixture()
        let older = Conversation(title: "常用", messages: [], updatedAt: Date(timeIntervalSinceReferenceDate: 10))
        let newer = Conversation(title: "最近", messages: [], updatedAt: Date(timeIntervalSinceReferenceDate: 20))
        try JSONEncoder().encode([older, newer]).write(to: fixture.directory.appendingPathComponent("conversations.json"))
        let model = fixture.model()
        XCTAssertEqual(model.conversations.map(\.id), [newer.id, older.id])
        XCTAssertFalse(model.conversations.contains { $0.isPinned })
        model.togglePin(older.id)
        XCTAssertEqual(model.conversations.map(\.id), [older.id, newer.id])
        let reloaded = fixture.model()
        XCTAssertTrue(reloaded.conversations[0].isPinned)
        let originalProfile = reloaded.activeProfileID
        _ = try reloaded.saveProfile(id: nil, name: "另一连接", connection: ConnectionSettings(serverURL: "https://other.test/v1", model: "hermes-agent", apiKey: "key"))
        reloaded.togglePin(older.id)
        reloaded.rename(older.id, to: "不应影响另一连接")
        reloaded.selectProfile(originalProfile)
        XCTAssertTrue(reloaded.conversations[0].isPinned)
        XCTAssertEqual(reloaded.conversations[0].title, "常用")
        reloaded.togglePin(older.id)
        XCTAssertEqual(reloaded.conversations.map(\.id), [newer.id, older.id])
    }

    @MainActor
    func testExportRejectsMissingImageInsteadOfCreatingIncompleteBackup() throws {
        let source = try makeSource()
        let id = try XCTUnwrap(source.model.conversations.flatMap(\.messages).compactMap(\.imageID).first)
        ImageAttachmentStore.remove(id, directory: source.model.attachmentDirectory)
        XCTAssertThrowsError(try source.model.makeBackup())
    }

    @MainActor
    private func makeSource() throws -> BackupSource {
        let fixture = try makeFixture()
        fixture.defaults.set("https://source.test/v1", forKey: "serverURL")
        fixture.keys.values["api-server-key"] = "source-secret"
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 12))
        let image = try XCTUnwrap(renderer.image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 12))
        }.jpegData(compressionQuality: 0.8))
        let imageID = try ImageAttachmentStore.save(image, directory: fixture.directory.appendingPathComponent("Attachments"))
        let first = Conversation(title: "图片会话", messages: [ChatMessage(role: .user, content: "描述图片", imageID: imageID)],
                                 updatedAt: Date(timeIntervalSinceReferenceDate: 20), pinned: true)
        let second = Conversation(title: "文字会话", messages: [ChatMessage(role: .assistant, content: "你好")],
                                  updatedAt: Date(timeIntervalSinceReferenceDate: 10))
        try JSONEncoder().encode([first, second]).write(to: fixture.directory.appendingPathComponent("conversations.json"))
        let model = fixture.model()
        model.draft = "会话草稿"
        model.newConversation()
        model.draft = "新对话草稿"
        model.select(first.id)
        try model.draftStore.set("远端草稿", for: DraftStore.remoteKey(settings: model.settings, sessionID: "api_example"))
        return BackupSource(fixture: fixture, model: model, image: image)
    }

    @MainActor
    private func makeFixture() throws -> BackupFixture {
        let suite = "HermesBackupTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return BackupFixture(defaults: defaults, directory: directory, keys: MemoryCredentials())
    }
}

private struct BackupFixture {
    let defaults: UserDefaults
    let directory: URL
    let keys: MemoryCredentials
    @MainActor func model() -> AppModel { AppModel(defaults: defaults, directory: directory, credentials: keys) }
}

private struct BackupSource {
    let fixture: BackupFixture
    let model: AppModel
    let image: Data
}
