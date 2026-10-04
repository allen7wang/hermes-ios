import Foundation
import CryptoKit
import ImageIO

struct BackupArchive: Codable {
    static let byteLimit = 64_000_000
    var format = "hermes-ios-backup"
    var version = 1
    let installationID: UUID
    let createdAt: Date
    var profiles: [ConnectionProfile]
    var conversations: [Conversation]
    var drafts: [String: String]
    var images: [String: Data]

    var bookmarkCount: Int { conversations.reduce(0) { $0 + $1.messages.filter { $0.bookmark != nil }.count } }

    static func read(from url: URL) throws -> BackupArchive {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try decode(file.read(upToCount: byteLimit + 1) ?? Data())
    }

    static func decode(_ data: Data) throws -> BackupArchive {
        guard data.count <= byteLimit else { throw BackupError.tooLarge }
        let archive: BackupArchive
        do { archive = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw BackupError.invalidFile }
        try archive.validate()
        return archive
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.byteLimit else { throw BackupError.tooLarge }
        return data
    }

    func validate() throws {
        guard format == "hermes-ios-backup" else { throw BackupError.invalidFile }
        guard (1...2).contains(version) else { throw BackupError.unsupportedVersion }
        guard !profiles.isEmpty, profiles.count <= 100,
              conversations.count <= 5_000,
              conversations.reduce(0, { $0 + $1.messages.count }) <= 100_000,
              Set(profiles.map(\.id)).count == profiles.count,
              Set(conversations.map(\.id)).count == conversations.count else { throw BackupError.invalidFile }
        let profileIDs = Set(profiles.map(\.id))
        var conversationProfiles: [UUID: UUID] = [:]
        var referencedImages = Set<String>()
        for profile in profiles {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackupError.invalidFile }
            if !profile.serverURL.isEmpty { _ = try HermesClient(settings: profile.settings(apiKey: "")).rootURL }
        }
        for conversation in conversations {
            guard let profileID = conversation.profileID, profileIDs.contains(profileID),
                  Set(conversation.messages.map(\.id)).count == conversation.messages.count else { throw BackupError.invalidFile }
            conversationProfiles[conversation.id] = profileID
            referencedImages.formUnion(conversation.messages.compactMap { $0.imageID?.uuidString })
            for message in conversation.messages {
                if let bookmark = message.bookmark {
                    guard version >= 2, bookmark.note.count <= MessageBookmark.noteLimit,
                          bookmark.createdAt.timeIntervalSince1970.isFinite else { throw BackupError.invalidFile }
                }
            }
        }
        guard Set(images.keys) == referencedImages else { throw BackupError.missingImage }
        for (key, data) in images {
            guard UUID(uuidString: key) != nil, data.count <= 2_000_000,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == "public.jpeg",
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...1600).contains(width), (1...1600).contains(height) else { throw BackupError.invalidImage }
        }
        for (key, value) in drafts {
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3, let profileID = UUID(uuidString: parts[0]), profileIDs.contains(profileID),
                  !parts[2].isEmpty, value.count <= 100_000 else { throw BackupError.invalidFile }
            if parts[1] == "local" {
                guard parts[2] == "new" || UUID(uuidString: parts[2]).map({ conversationProfiles[$0] == profileID }) == true else {
                    throw BackupError.invalidFile
                }
            } else if parts[1] != "remote" { throw BackupError.invalidFile }
        }
    }
}

struct BackupImportReport {
    let profilesAdded: Int
    let conversationsAdded: Int
    let conversationsKept: Int
    let draftsAdded: Int
    let imagesAdded: Int

    var description: String {
        "新增 \(profilesAdded) 个连接、\(conversationsAdded) 段对话、\(draftsAdded) 份草稿和 \(imagesAdded) 张图片；保留 \(conversationsKept) 段已有对话。"
    }
}

struct BackupMerge {
    let state: BackupRestoreState
    let report: BackupImportReport

    static func prepare(_ archive: BackupArchive, installationID: UUID,
                        library: ConnectionLibrary, conversations: [Conversation], drafts: [String: String]) throws -> BackupMerge {
        try archive.validate()
        var profiles = library.profiles
        var records = conversations
        var texts = drafts
        var images: [String: Data] = [:]
        var profileMap: [UUID: UUID] = [:]
        var conversationMap: [UUID: UUID] = [:]
        var kept = 0
        for profile in archive.profiles {
            let endpoint = try identity(profile)
            // Only the same installation can match an original ID. Fresh imports receive stable IDs.
            let original = profiles.first {
                $0.id == profile.id && archive.installationID == installationID && (try? identity($0)) == endpoint
            }
            let target = original?.id ?? stableID([archive.installationID.uuidString, profile.id.uuidString, endpoint])
            profileMap[profile.id] = target
            if !profiles.contains(where: { $0.id == target }) {
                var imported = profile
                imported.id = target
                imported.name = String(profile.name.prefix(60)) + "（已导入）"
                profiles.append(imported)
            }
        }
        for conversation in archive.conversations {
            guard let sourceProfile = conversation.profileID, let targetProfile = profileMap[sourceProfile] else { throw BackupError.invalidFile }
            let original = conversations.first { $0.id == conversation.id && $0.profileID == targetProfile }
            let targetID = original?.id ?? stableID([archive.installationID.uuidString, conversation.id.uuidString, targetProfile.uuidString])
            conversationMap[conversation.id] = targetID
            if records.contains(where: { $0.id == targetID }) { kept += 1; continue }
            var imported = conversation
            imported.id = targetID
            imported.profileID = targetProfile
            for index in imported.messages.indices {
                guard let imageID = imported.messages[index].imageID,
                      let data = archive.images[imageID.uuidString] else { continue }
                let mapped = stableID([archive.installationID.uuidString, imageID.uuidString, Data(SHA256.hash(data: data)).base64EncodedString()])
                imported.messages[index].imageID = mapped
                images[mapped.uuidString] = data
            }
            records.append(imported)
        }
        var draftsAdded = 0
        for (key, value) in archive.drafts where !value.isEmpty {
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            guard let sourceProfile = UUID(uuidString: parts[0]), let targetProfile = profileMap[sourceProfile] else { throw BackupError.invalidFile }
            let suffix: String
            if parts[1] == "local", let conversationID = UUID(uuidString: parts[2]) {
                guard let targetID = conversationMap[conversationID] else { throw BackupError.invalidFile }
                suffix = targetID.uuidString
            } else { suffix = parts[2] }
            let targetKey = "\(targetProfile.uuidString)/\(parts[1])/\(suffix)"
            if texts[targetKey]?.isEmpty != false { texts[targetKey] = value; draftsAdded += 1 }
        }
        let mergedLibrary = ConnectionLibrary(profiles: profiles, activeID: library.activeID,
                                              selectedConversations: library.selectedConversations)
        return BackupMerge(state: BackupRestoreState(library: mergedLibrary, conversations: records, drafts: texts, images: images),
                           report: BackupImportReport(profilesAdded: profiles.count - library.profiles.count,
                                                      conversationsAdded: records.count - conversations.count,
                                                      conversationsKept: kept, draftsAdded: draftsAdded, imagesAdded: images.count))
    }

    private static func identity(_ profile: ConnectionProfile) throws -> String {
        profile.serverURL.isEmpty ? "" : try HermesClient(settings: profile.settings(apiKey: "")).rootURL.absoluteString
    }

    private static func stableID(_ parts: [String]) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct BackupRestoreState: Codable {
    let library: ConnectionLibrary
    let conversations: [Conversation]
    let drafts: [String: String]
    let images: [String: Data]
}

// A journal makes an interrupted import repeatable on the next launch. Existing keys are never written.
enum BackupRestoreTransaction {
    static func preserveOriginals(directory: URL, defaults: UserDefaults) throws {
        let destination = directory.appendingPathComponent("Recovery/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["connections.json", "conversations.json", "drafts.json", "pending-restore.json"] {
            let source = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(name))
            }
        }
        if let data = defaults.data(forKey: "connectionLibrary") {
            try data.write(to: destination.appendingPathComponent("connectionLibrary-cache.json"), options: .atomic)
        }
    }

    static func recover(directory: URL, defaults: UserDefaults) throws {
        let journal = directory.appendingPathComponent("pending-restore.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let state = try JSONDecoder().decode(BackupRestoreState.self, from: Data(contentsOf: journal))
        try apply(state, directory: directory, defaults: defaults)
    }

    static func commit(_ state: BackupRestoreState, directory: URL, defaults: UserDefaults) throws {
        let journal = directory.appendingPathComponent("pending-restore.json")
        try JSONEncoder().encode(state).write(to: journal, options: [.atomic, .completeFileProtectionUnlessOpen])
        try apply(state, directory: directory, defaults: defaults)
    }

    private static func apply(_ state: BackupRestoreState, directory: URL, defaults: UserDefaults) throws {
        for (key, data) in state.images {
            guard let id = UUID(uuidString: key) else { throw BackupError.invalidFile }
            let imageDirectory = directory.appendingPathComponent("Attachments", isDirectory: true)
            let url = ImageAttachmentStore.fileURL(for: id, directory: imageDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                guard try Data(contentsOf: url) == data else { throw BackupError.imageConflict }
            } else { _ = try ImageAttachmentStore.save(data, id: id, directory: imageDirectory) }
        }
        let encoder = JSONEncoder()
        try encoder.encode(state.conversations).write(to: directory.appendingPathComponent("conversations.json"), options: .atomic)
        try encoder.encode(state.drafts).write(to: directory.appendingPathComponent("drafts.json"), options: .atomic)
        let libraryData = try encoder.encode(state.library)
        try libraryData.write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        defaults.set(libraryData, forKey: "connectionLibrary")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("pending-restore.json"))
    }
}

enum BackupError: LocalizedError {
    case invalidFile, unsupportedVersion, tooLarge, missingImage, invalidImage, imageConflict
    var errorDescription: String? {
        switch self {
        case .invalidFile: "这不是有效的 Hermes 备份，或其中的记录不完整。"
        case .unsupportedVersion: "此备份版本暂不支持，请更新 App 后重试。"
        case .tooLarge: "备份超过 64 MB，暂时无法导入或导出。"
        case .missingImage: "备份缺少对话引用的图片，请重新导出完整备份。"
        case .invalidImage: "备份包含无效或超出大小限制的图片。"
        case .imageConflict: "备份图片与本机文件冲突，原图片已保留。"
        }
    }
}
