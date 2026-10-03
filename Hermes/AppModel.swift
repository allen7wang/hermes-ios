import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState {
        case unconfigured
        case checking
        case connected
        case offline
    }

    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isSending = false
    @Published private(set) var streamedReply = ""
    @Published private(set) var toolStatus: String?
    @Published var errorMessage: String?
    @Published var settings: ConnectionSettings
    @Published private(set) var connectionState: ConnectionState = .unconfigured

    private var activeTask: Task<Void, Never>?
    private let conversationsURL: URL

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedID }
    }

    init() {
        let defaults = UserDefaults.standard
        let initialSettings = ConnectionSettings(
            serverURL: defaults.string(forKey: "serverURL") ?? "",
            model: defaults.string(forKey: "model") ?? "hermes-agent",
            apiKey: KeychainStore.readKey()
        )
        settings = initialSettings
        connectionState = initialSettings.isConfigured ? .checking : .unconfigured
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
        connectionState = newSettings.isConfigured ? .checking : .unconfigured
        UserDefaults.standard.set(newSettings.serverURL, forKey: "serverURL")
        UserDefaults.standard.set(newSettings.model, forKey: "model")
    }

    func checkConnection() async {
        let current = settings
        guard current.isConfigured else {
            connectionState = .unconfigured
            return
        }
        connectionState = .checking
        do {
            _ = try await HermesClient(settings: current).availableModels()
            if settings == current { connectionState = .connected }
        } catch {
            if settings == current { connectionState = .offline }
        }
    }

    func recordConnectionTest(success: Bool) {
        connectionState = success ? .connected : .offline
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
        if let conversation = conversations.first(where: { $0.id == id }) {
            for imageID in conversation.messages.compactMap(\.imageID) {
                ImageAttachmentStore.remove(imageID)
            }
        }
        conversations.removeAll { $0.id == id }
        if selectedID == id { selectedID = conversations.first?.id }
        persist()
    }

    func rename(_ id: UUID, to rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = String(title.prefix(80))
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

    @discardableResult
    func send(_ rawText: String, imageData: Data? = nil) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || imageData != nil, !isSending else { return false }
        guard settings.isConfigured else {
            errorMessage = "请先在连接设置中填写 Hermes 服务地址和 API 密钥。"
            return false
        }

        var imageID: UUID?
        if let imageData {
            do { imageID = try ImageAttachmentStore.save(imageData) }
            catch {
                errorMessage = error.localizedDescription
                return false
            }
        }

        if selectedID == nil {
            let title = text.isEmpty ? "图片对话" : String(text.prefix(38))
            let conversation = Conversation(title: title, messages: [], updatedAt: Date())
            conversations.insert(conversation, at: 0)
            selectedID = conversation.id
        }
        guard let selectedID, let index = conversations.firstIndex(where: { $0.id == selectedID }) else {
            if let imageID { ImageAttachmentStore.remove(imageID) }
            return false
        }
        conversations[index].messages.append(
            ChatMessage(role: .user, content: text, imageID: imageID)
        )
        conversations[index].updatedAt = Date()
        persist()
        requestResponse(for: selectedID)
        return true
    }

    private func requestResponse(for id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        let history = conversation.messages
        let connection = settings
        isSending = true
        streamedReply = ""
        toolStatus = nil

        activeTask = Task {
            defer {
                isSending = false
                activeTask = nil
                streamedReply = ""
                toolStatus = nil
            }
            do {
                let reply = try await HermesClient(settings: connection).stream(
                    messages: history
                ) { event in
                    await MainActor.run {
                        switch event {
                        case .delta(let text):
                            streamedReply += text
                            toolStatus = nil
                        case .tool(let progress):
                            if progress.status == "completed" {
                                toolStatus = nil
                            } else {
                                toolStatus = [progress.emoji, progress.label ?? progress.tool]
                                    .compactMap { $0 }
                                    .joined(separator: " ")
                            }
                        }
                    }
                }
                if !Task.isCancelled,
                   let index = conversations.firstIndex(where: { $0.id == id }) {
                    connectionState = .connected
                    conversations[index].messages.append(
                        ChatMessage(role: .assistant, content: reply, createdAt: Date())
                    )
                    conversations[index].updatedAt = Date()
                    persist()
                }
            } catch {
                if !Task.isCancelled {
                    if error is URLError { connectionState = .offline }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func persist() {
        let ordered = conversations.sorted { $0.updatedAt > $1.updatedAt }
        conversations = ordered
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        try? data.write(to: conversationsURL, options: .atomic)
    }
}
