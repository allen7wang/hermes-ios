import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isSending = false
    @Published var errorMessage: String?
    @Published var settings: ConnectionSettings

    private var activeTask: Task<Void, Never>?
    private let conversationsURL: URL

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedID }
    }

    init() {
        let defaults = UserDefaults.standard
        settings = ConnectionSettings(
            serverURL: defaults.string(forKey: "serverURL") ?? "",
            model: defaults.string(forKey: "model") ?? "hermes-agent",
            apiKey: KeychainStore.readKey()
        )
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        conversationsURL = directory.appendingPathComponent("conversations.json")
        if let data = try? Data(contentsOf: conversationsURL),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved.sorted { $0.updatedAt > $1.updatedAt }
            selectedID = conversations.first?.id
        }
    }

    func saveSettings(_ newSettings: ConnectionSettings) throws {
        try KeychainStore.saveKey(newSettings.apiKey)
        settings = newSettings
        UserDefaults.standard.set(newSettings.serverURL, forKey: "serverURL")
        UserDefaults.standard.set(newSettings.model, forKey: "model")
    }

    func newConversation() {
        guard !isSending else { return }
        selectedID = nil
    }

    func select(_ id: UUID) {
        guard !isSending else { return }
        selectedID = id
    }

    func delete(_ id: UUID) {
        guard !isSending else { return }
        conversations.removeAll { $0.id == id }
        if selectedID == id { selectedID = conversations.first?.id }
        persist()
    }

    func cancelSend() {
        activeTask?.cancel()
    }

    func retryLastResponse() {
        guard !isSending,
              settings.isConfigured,
              let selectedID,
              let conversation = selectedConversation,
              conversation.messages.last?.role == .user else { return }
        requestResponse(for: selectedID)
    }

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard settings.isConfigured else {
            errorMessage = "请先在连接设置中填写 Hermes 服务地址和 API 密钥。"
            return
        }

        if selectedID == nil {
            let title = String(text.prefix(38))
            let conversation = Conversation(title: title, messages: [], updatedAt: Date())
            conversations.insert(conversation, at: 0)
            selectedID = conversation.id
        }
        guard let selectedID, let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        conversations[index].messages.append(
            ChatMessage(role: .user, content: text, createdAt: Date())
        )
        conversations[index].updatedAt = Date()
        persist()
        requestResponse(for: selectedID)
    }

    private func requestResponse(for id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        let history = conversation.messages
        let connection = settings
        isSending = true

        activeTask = Task {
            do {
                let reply = try await HermesClient(settings: connection).complete(messages: history)
                if !Task.isCancelled,
                   let index = conversations.firstIndex(where: { $0.id == id }) {
                    conversations[index].messages.append(
                        ChatMessage(role: .assistant, content: reply, createdAt: Date())
                    )
                    conversations[index].updatedAt = Date()
                    persist()
                }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isSending = false
            activeTask = nil
        }
    }

    private func persist() {
        let ordered = conversations.sorted { $0.updatedAt > $1.updatedAt }
        conversations = ordered
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        try? data.write(to: conversationsURL, options: .atomic)
    }
}
