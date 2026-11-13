import Foundation

struct InboxItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case approval, finished, failed }

    var id: String
    var profileID: UUID?
    var sessionID: String
    var sessionTitle: String
    var runID: String?
    var requestID: String?
    var command: String?
    var choices: [String]?
    var kind: Kind
    var title: String
    var detail: String
    var createdAt: Date
}

enum InboxStore {
    static let didChange = Notification.Name("HermesInboxDidChange")

    private static let lock = NSLock()
    private static var backingURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("inbox-items.json")
    }()

    static var storageURL: URL {
        get {
            lock.lock()
            defer { lock.unlock() }
            return backingURL
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            backingURL = newValue
        }
    }

    static func upsert(_ item: InboxItem) throws {
        try mutate { items in
            if let index = items.firstIndex(where: { $0.id == item.id && $0.profileID == item.profileID }) {
                items[index] = item
            } else {
                items.append(item)
            }
        }
    }

    static func remove(id: String, profileID: UUID?) throws {
        try mutate { items in
            items.removeAll { $0.id == id && $0.profileID == profileID }
        }
    }

    static func removeAll(profileID: UUID) throws {
        try mutate { items in
            items.removeAll { $0.profileID == profileID }
        }
    }

    static func items(profileID: UUID?) throws -> [InboxItem] {
        lock.lock()
        defer { lock.unlock() }
        return try load(from: backingURL).filter { $0.profileID == profileID }.sorted(by: newerFirst)
    }

    private static func mutate(_ body: (inout [InboxItem]) -> Void) throws {
        lock.lock()
        do {
            var items = try load(from: backingURL)
            body(&items)
            try save(items, to: backingURL)
            lock.unlock()
            notify()
        } catch {
            lock.unlock()
            throw error
        }
    }

    private static func load(from url: URL) throws -> [InboxItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([InboxItem].self, from: Data(contentsOf: url))
    }

    private static func save(_ items: [InboxItem], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var fileURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try fileURL.setResourceValues(values)
    }

    private static func newerFirst(_ lhs: InboxItem, _ rhs: InboxItem) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id > rhs.id
    }

    private static func notify() {
        let post = { NotificationCenter.default.post(name: didChange, object: nil) }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }
}
