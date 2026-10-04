import Foundation

@MainActor
final class DraftStore {
    private let url: URL
    private var values: [String: String] = [:]
    private var loadError: Error?

    init(directory: URL) {
        url = directory.appendingPathComponent("drafts.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)) }
            catch { loadError = error }
        }
    }

    static func localKey(profileID: UUID, conversationID: UUID?) -> String {
        "\(profileID.uuidString)/local/\(conversationID?.uuidString ?? "new")"
    }

    static func remoteKey(settings: ConnectionSettings, sessionID: String) -> String {
        // App connections always have a profile ID. URL scoping also supports standalone clients.
        "\(settings.profileID?.uuidString ?? settings.serverURL)/remote/\(sessionID)"
    }

    var isReadable: Bool { loadError == nil }

    func snapshot() throws -> [String: String] {
        if let loadError { throw loadError }
        return values
    }

    func reload() throws {
        values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        loadError = nil
    }

    func text(for key: String) -> String { values[key] ?? "" }

    func set(_ text: String, for key: String) throws {
        var next = values
        next[key] = text.isEmpty ? nil : text
        try write(next)
    }

    func remove(profileID: UUID) throws {
        try write(values.filter { !$0.key.hasPrefix("\(profileID.uuidString)/") })
    }

    func move(from oldKey: String, to newKey: String) throws {
        guard oldKey != newKey, let value = values[oldKey] else { return }
        var next = values
        next[newKey] = value
        next[oldKey] = nil
        try write(next)
    }

    private func write(_ next: [String: String]) throws {
        if let loadError { throw loadError }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        values = next
    }
}
