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
    @Published private(set) var settings: ConnectionSettings
    @Published private(set) var profiles: [ConnectionProfile]
    @Published private(set) var activeProfileID: UUID
    @Published var draft = "" {
        didSet {
            do { try draftStore.set(draft, for: draftKey) }
            catch { errorMessage = "草稿保存失败：\(error.localizedDescription)" }
        }
    }
    @Published private(set) var connectionState: ConnectionState = .unconfigured

    private var activeTask: Task<Void, Never>?
    private let conversationsURL: URL
    private let defaults: UserDefaults
    private let credentials: CredentialStore
    private let sessionConfiguration: URLSessionConfiguration
    private var storageLoadFailed = false
    private var allConversations: [Conversation] = []
    private var selectedConversations: [String: String] = [:]
    let draftStore: DraftStore

    var activeProfileName: String { profiles.first { $0.id == activeProfileID }?.name ?? "Hermes" }
    var draftKey: String { DraftStore.localKey(profileID: activeProfileID, conversationID: selectedID) }

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedID }
    }

    init(defaults: UserDefaults = .standard, directory: URL? = nil,
         credentials: CredentialStore = SystemCredentialStore(),
         sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.defaults = defaults
        self.credentials = credentials
        self.sessionConfiguration = sessionConfiguration
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        conversationsURL = directory.appendingPathComponent("conversations.json")
        draftStore = DraftStore(directory: directory)

        let libraryData = defaults.data(forKey: "connectionLibrary")
        let library = libraryData.flatMap { try? JSONDecoder().decode(ConnectionLibrary.self, from: $0) }
        let legacy = ConnectionProfile(id: ConnectionProfile.legacyID, name: "默认连接",
                                       serverURL: defaults.string(forKey: "serverURL") ?? "",
                                       model: defaults.string(forKey: "model") ?? "hermes-agent")
        let savedProfiles = library?.profiles.isEmpty == false ? library!.profiles : [legacy]
        profiles = savedProfiles
        let active = savedProfiles.first { $0.id == library?.activeID } ?? savedProfiles[0]
        activeProfileID = active.id
        settings = active.settings(apiKey: credentials.read(account: active.credentialAccount))
        selectedConversations = library?.selectedConversations ?? [:]
        connectionState = settings.isConfigured ? .checking : .unconfigured
        if libraryData != nil && (library == nil || library!.profiles.isEmpty) {
            storageLoadFailed = true
            errorMessage = ProfileError.storageUnavailable.localizedDescription
        }
        if FileManager.default.fileExists(atPath: conversationsURL.path) {
            do {
                let saved = try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: conversationsURL))
                allConversations = saved.map { conversation in
                    var migrated = conversation
                    if migrated.profileID == nil { migrated.profileID = savedProfiles[0].id }
                    return migrated
                }
            } catch {
                storageLoadFailed = true
                errorMessage = "本机对话文件无法读取，已保留原文件。请先恢复备份再发送消息。"
            }
        }
        refreshConversations()
        restoreSelection()
        draft = draftStore.text(for: draftKey)
        persistLibrary()
        persist()
    }

    /// A changed endpoint creates a new profile so existing history keeps its original destination.
    @discardableResult
    func saveProfile(id: UUID?, name: String, connection: ConnectionSettings) throws -> UUID {
        guard !isSending else { throw ProfileError.sending }
        guard !storageLoadFailed else { throw ProfileError.storageUnavailable }
        let root = try HermesClient(settings: connection).rootURL
        guard !connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileError.missingKey
        }
        let existing = profiles.first { $0.id == id }
        let oldRoot = existing.flatMap { try? HermesClient(settings: $0.settings(apiKey: "")).rootURL }
        let keepsIdentity = existing != nil && (existing!.serverURL.isEmpty || oldRoot == root)
        let profile = ConnectionProfile(
            id: keepsIdentity ? existing!.id : UUID(),
            name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)),
            serverURL: connection.serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "hermes-agent" : connection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !profile.name.isEmpty else { throw ProfileError.missingName }
        try credentials.save(connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: profile.credentialAccount)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        activate(profile)
        return profile.id
    }

    func key(for id: UUID) -> String {
        guard let profile = profiles.first(where: { $0.id == id }) else { return "" }
        return credentials.read(account: profile.credentialAccount)
    }

    func selectProfile(_ id: UUID) {
        guard !isSending, let profile = profiles.first(where: { $0.id == id }) else { return }
        activate(profile)
    }

    func removeProfile(_ id: UUID) throws {
        guard !isSending else { throw ProfileError.sending }
        guard !storageLoadFailed else { throw ProfileError.storageUnavailable }
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        try credentials.save("", account: profile.credentialAccount)
        try draftStore.remove(profileID: id)
        for imageID in allConversations.filter({ $0.profileID == id }).flatMap({ $0.messages.compactMap(\.imageID) }) {
            ImageAttachmentStore.remove(imageID)
        }
        allConversations.removeAll { $0.profileID == id }
        profiles.removeAll { $0.id == id }
        selectedConversations[id.uuidString] = nil
        if profiles.isEmpty { profiles = [ConnectionProfile(name: "默认连接", serverURL: "", model: "hermes-agent")] }
        if activeProfileID == id { activate(profiles[0]) }
        else { persistLibrary(); refreshConversations() }
        persist()
    }

    private func activate(_ profile: ConnectionProfile) {
        activeProfileID = profile.id
        settings = profile.settings(apiKey: credentials.read(account: profile.credentialAccount))
        connectionState = settings.isConfigured ? .checking : .unconfigured
        errorMessage = nil
        refreshConversations()
        restoreSelection()
        draft = draftStore.text(for: draftKey)
        persistLibrary()
    }

    private func restoreSelection() {
        if let saved = selectedConversations[activeProfileID.uuidString] {
            selectedID = conversations.first { $0.id.uuidString == saved }?.id
        } else { selectedID = conversations.first?.id }
    }

    private func rememberSelection() {
        selectedConversations[activeProfileID.uuidString] = selectedID?.uuidString ?? ""
        persistLibrary()
        draft = draftStore.text(for: draftKey)
    }

    private func persistLibrary() {
        guard !storageLoadFailed else { return }
        let library = ConnectionLibrary(profiles: profiles, activeID: activeProfileID,
                                        selectedConversations: selectedConversations)
        if let data = try? JSONEncoder().encode(library) { defaults.set(data, forKey: "connectionLibrary") }
    }

    func checkConnection() async {
        let current = settings
        guard current.isConfigured else {
            connectionState = .unconfigured
            return
        }
        connectionState = .checking
        do {
            _ = try await HermesClient(settings: current, sessionConfiguration: sessionConfiguration).availableModels()
            if settings == current { connectionState = .connected }
        } catch {
            if settings == current { connectionState = .offline }
        }
    }

    func recordConnectionTest(success: Bool, settings tested: ConnectionSettings) {
        guard settings == tested else { return }
        connectionState = success ? .connected : .offline
    }

    func newConversation() {
        guard !isSending else { return }
        selectedID = nil
        rememberSelection()
    }

    func select(_ id: UUID) {
        guard !isSending, conversations.contains(where: { $0.id == id }) else { return }
        selectedID = id
        rememberSelection()
    }

    func delete(_ id: UUID) {
        guard !isSending, !storageLoadFailed else { return }
        if let conversation = conversations.first(where: { $0.id == id }) {
            for imageID in conversation.messages.compactMap(\.imageID) {
                ImageAttachmentStore.remove(imageID)
            }
        }
        allConversations.removeAll { $0.id == id && $0.profileID == activeProfileID }
        do { try draftStore.set("", for: DraftStore.localKey(profileID: activeProfileID, conversationID: id)) }
        catch { errorMessage = error.localizedDescription }
        refreshConversations()
        if selectedID == id { selectedID = conversations.first?.id; rememberSelection() }
        persist()
    }

    func rename(_ id: UUID, to rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storageLoadFailed, !title.isEmpty, let index = allConversations.firstIndex(where: { $0.id == id }) else { return }
        allConversations[index].title = String(title.prefix(80))
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
        guard !storageLoadFailed else {
            errorMessage = ProfileError.storageUnavailable.localizedDescription
            return false
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || imageData != nil, !isSending else { return false }
        guard settings.isConfigured else {
            errorMessage = "请先在连接管理中填写 Hermes 服务地址和 API 密钥。"
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

        let sentDraftKey = draftKey
        if selectedID == nil {
            let title = text.isEmpty ? "图片对话" : String(text.prefix(38))
            let conversation = Conversation(title: title, messages: [], updatedAt: Date(), profileID: activeProfileID)
            allConversations.insert(conversation, at: 0)
            selectedID = conversation.id
        }
        guard let selectedID, let index = allConversations.firstIndex(where: { $0.id == selectedID }) else {
            if let imageID { ImageAttachmentStore.remove(imageID) }
            return false
        }
        allConversations[index].messages.append(
            ChatMessage(role: .user, content: text, imageID: imageID)
        )
        allConversations[index].updatedAt = Date()
        persist()
        do { try draftStore.set("", for: sentDraftKey) }
        catch { errorMessage = "草稿清理失败：\(error.localizedDescription)" }
        rememberSelection()
        draft = ""
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
                let reply = try await HermesClient(settings: connection, sessionConfiguration: sessionConfiguration).stream(
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
                   let index = allConversations.firstIndex(where: { $0.id == id }) {
                    connectionState = .connected
                    allConversations[index].messages.append(
                        ChatMessage(role: .assistant, content: reply, createdAt: Date())
                    )
                    allConversations[index].updatedAt = Date()
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

    private func refreshConversations() {
        conversations = allConversations.filter { $0.profileID == activeProfileID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        guard !storageLoadFailed else { return }
        refreshConversations()
        do { try JSONEncoder().encode(allConversations).write(to: conversationsURL, options: .atomic) }
        catch { errorMessage = "对话保存失败：\(error.localizedDescription)" }
    }

    enum ProfileError: LocalizedError {
        case sending, missingName, missingKey, storageUnavailable
        var errorDescription: String? {
            switch self {
            case .storageUnavailable: "本机连接或对话数据无法读取，请先恢复备份。原数据已保留。"
            case .sending: "请等待回复完成或停止后，再修改连接。"
            case .missingName: "请填写连接名称。"
            case .missingKey: "请填写 API 密钥。"
            }
        }
    }
}
