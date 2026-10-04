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
            guard !draftAlreadyPersisted else { return }
            do { try draftStore.set(draft, for: draftKey) }
            catch { errorMessage = "草稿保存失败：\(error.localizedDescription)" }
        }
    }
    @Published private(set) var connectionState: ConnectionState = .unconfigured

    private var activeTask: Task<Void, Never>?
    private let conversationsURL: URL
    private let directory: URL
    private let recoveryProfileID = UUID()
    private let installationID: UUID
    private let defaults: UserDefaults
    private let credentials: CredentialStore
    private let sessionConfiguration: URLSessionConfiguration
    private var storageLoadFailed = false
    private var draftAlreadyPersisted = false
    private var allConversations: [Conversation] = []
    private var selectedConversations: [String: String] = [:]
    let draftStore: DraftStore

    var activeProfileName: String { profiles.first { $0.id == activeProfileID }?.name ?? "Hermes" }
    var draftKey: String { DraftStore.localKey(profileID: activeProfileID, conversationID: selectedID) }

    var needsRecovery: Bool { storageLoadFailed || !draftStore.isReadable }

    var attachmentDirectory: URL { directory.appendingPathComponent("Attachments", isDirectory: true) }

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
        self.directory = directory
        conversationsURL = directory.appendingPathComponent("conversations.json")
        let installation = defaults.string(forKey: "installationID").flatMap(UUID.init(uuidString:)) ?? UUID()
        installationID = installation
        defaults.set(installation.uuidString, forKey: "installationID")
        var recoveryError: Error?
        do { try BackupRestoreTransaction.recover(directory: directory, defaults: defaults) }
        catch { recoveryError = error }
        draftStore = DraftStore(directory: directory)

        let libraryURL = directory.appendingPathComponent("connections.json")
        let libraryFileExists = FileManager.default.fileExists(atPath: libraryURL.path)
        let libraryData = libraryFileExists ? try? Data(contentsOf: libraryURL) : defaults.data(forKey: "connectionLibrary")
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
        if recoveryError != nil || (libraryFileExists && libraryData == nil) ||
            (libraryData != nil && (library == nil || library!.profiles.isEmpty)) {
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
        let removedImages = Set(allConversations.filter({ $0.profileID == id }).flatMap({ $0.messages.compactMap(\.imageID) }))
        allConversations.removeAll { $0.profileID == id }
        removeUnusedImages(removedImages)
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
        do {
            let data = try JSONEncoder().encode(library)
            try data.write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
            defaults.set(data, forKey: "connectionLibrary")
        } catch { errorMessage = "连接保存失败：\(error.localizedDescription)" }
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
        let removedImages = Set(conversations.first(where: { $0.id == id })?.messages.compactMap(\.imageID) ?? [])
        allConversations.removeAll { $0.id == id && $0.profileID == activeProfileID }
        removeUnusedImages(removedImages)
        do { try draftStore.set("", for: DraftStore.localKey(profileID: activeProfileID, conversationID: id)) }
        catch { errorMessage = error.localizedDescription }
        refreshConversations()
        if selectedID == id { selectedID = conversations.first?.id; rememberSelection() }
        persist()
    }

    func rename(_ id: UUID, to rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storageLoadFailed, !title.isEmpty, let index = allConversations.firstIndex(where: { $0.id == id && $0.profileID == activeProfileID }) else { return }
        allConversations[index].title = String(title.prefix(80))
        persist()
    }

    func togglePin(_ id: UUID) {
        guard !storageLoadFailed, !isSending,
              let index = allConversations.firstIndex(where: { $0.id == id && $0.profileID == activeProfileID }) else { return }
        allConversations[index].pinned = !allConversations[index].isPinned
        persist()
    }

    func libraryItem(_ target: LocalMessageTarget) -> MessageLibraryItem? {
        guard let conversation = conversations.first(where: { $0.id == target.conversationID }),
              let message = conversation.messages.first(where: { $0.id == target.messageID }) else { return nil }
        return MessageLibraryItem(id: target, conversationTitle: conversation.title, message: message)
    }

    func toggleBookmark(_ target: LocalMessageTarget) throws {
        try changeBookmark(target) { current in
            current == nil ? MessageBookmark(createdAt: Date(), note: "") : nil
        }
    }

    func updateBookmarkNote(_ target: LocalMessageTarget, note: String) throws {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= MessageBookmark.noteLimit else { throw MessageLibraryError.noteTooLong }
        try changeBookmark(target) { current in
            guard var current else { throw MessageLibraryError.notBookmarked }
            current.note = note
            return current
        }
    }

    private func changeBookmark(_ target: LocalMessageTarget, transform: (MessageBookmark?) throws -> MessageBookmark?) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard let index = allConversations.firstIndex(where: { $0.id == target.conversationID && $0.profileID == activeProfileID }),
              let messageIndex = allConversations[index].messages.firstIndex(where: { $0.id == target.messageID }) else {
            throw MessageLibraryError.missing
        }
        var candidate = allConversations
        candidate[index].messages[messageIndex].bookmark = try transform(candidate[index].messages[messageIndex].bookmark)
        // Persist before publishing: a failed write must not show a successful star or note.
        try JSONEncoder().encode(candidate).write(to: conversationsURL, options: .atomic)
        allConversations = candidate
        refreshConversations()
    }

    func openMessage(_ target: LocalMessageTarget) throws {
        guard !isSending else { throw MessageLibraryError.busy }
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard libraryItem(target) != nil else { throw MessageLibraryError.missing }
        select(target.conversationID)
    }

    func quoteMessage(_ target: LocalMessageTarget) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard let item = libraryItem(target) else { throw MessageLibraryError.missing }
        let next = (draft.isEmpty ? "" : draft + "\n\n") + MessageLibrary.quote(item) + "\n\n"
        guard next.count <= 100_000 else { throw MessageLibraryError.draftTooLong }
        try draftStore.set(next, for: draftKey)
        draftAlreadyPersisted = true
        defer { draftAlreadyPersisted = false }
        draft = next
    }

    func makeBackup() throws -> BackupArchive {
        guard !isSending else { throw ProfileError.sending }
        guard !storageLoadFailed else { throw ProfileError.storageUnavailable }
        var images: [String: Data] = [:]
        var imageBytes = 0
        for id in Set(allConversations.flatMap { $0.messages.compactMap(\.imageID) }) {
            let data: Data
            do { data = try ImageAttachmentStore.load(id, directory: attachmentDirectory) }
            catch { throw BackupError.missingImage }
            imageBytes += data.count
            guard imageBytes <= BackupArchive.byteLimit / 4 * 3 else { throw BackupError.tooLarge }
            images[id.uuidString] = data
        }
        var archive = BackupArchive(installationID: installationID, createdAt: Date(), profiles: profiles,
                                    conversations: allConversations, drafts: try draftStore.snapshot(), images: images)
        if archive.bookmarkCount > 0 { archive.version = 2 }
        try archive.validate()
        return archive
    }

    func previewImport(_ archive: BackupArchive) throws -> BackupImportReport {
        try prepareImport(archive).report
    }

    @discardableResult
    func importBackup(_ archive: BackupArchive) throws -> BackupImportReport {
        let recovering = needsRecovery
        let merge = try prepareImport(archive)
        do {
            if recovering { try BackupRestoreTransaction.preserveOriginals(directory: directory, defaults: defaults) }
            try BackupRestoreTransaction.commit(merge.state, directory: directory, defaults: defaults)
            try draftStore.reload()
        } catch {
            // The journal is preserved for retry on next launch. Block further writes until recovery.
            storageLoadFailed = true
            errorMessage = "恢复未完成，原记录已保留。请重新打开 App 重试。"
            throw error
        }
        storageLoadFailed = false
        profiles = merge.state.library.profiles
        allConversations = merge.state.conversations
        if recovering {
            activeProfileID = merge.state.library.activeID
            selectedConversations = merge.state.library.selectedConversations
            selectedID = nil
            settings = profiles[0].settings(apiKey: credentials.read(account: profiles[0].credentialAccount))
            connectionState = .unconfigured
        }
        errorMessage = nil
        refreshConversations()
        draft = draftStore.text(for: draftKey)
        return merge.report
    }

    private func prepareImport(_ archive: BackupArchive) throws -> BackupMerge {
        guard !isSending else { throw ProfileError.sending }
        if needsRecovery {
            let empty = ConnectionProfile(id: recoveryProfileID, name: "默认连接", serverURL: "", model: "hermes-agent")
            return try BackupMerge.prepare(archive, installationID: installationID,
                library: ConnectionLibrary(profiles: [empty], activeID: empty.id), conversations: [], drafts: [:])
        }
        return try BackupMerge.prepare(archive, installationID: installationID,
            library: ConnectionLibrary(profiles: profiles, activeID: activeProfileID, selectedConversations: selectedConversations),
            conversations: allConversations, drafts: draftStore.snapshot())
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
    func branchConversation(at messageID: UUID) -> Bool {
        guard !isSending, !needsRecovery,
              let source = selectedConversation,
              let index = source.messages.firstIndex(where: { $0.id == messageID }) else { return false }
        return saveBranch(of: source, messages: Array(source.messages[...index])) != nil
    }

    @discardableResult
    func editAndResend(_ messageID: UUID, content: String, keepImage: Bool) -> Bool {
        guard !isSending, !needsRecovery,
              let source = selectedConversation,
              let index = source.messages.firstIndex(where: { $0.id == messageID }),
              source.messages[index].role == .user else { return false }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageID = keepImage ? source.messages[index].imageID : nil
        guard !text.isEmpty || imageID != nil else { return false }
        guard settings.isConfigured else {
            errorMessage = "请先在连接管理中填写 Hermes 服务地址和 API 密钥。"
            return false
        }
        if let imageID {
            do { _ = try ImageAttachmentStore.load(imageID, directory: attachmentDirectory) }
            catch {
                errorMessage = "原消息图片无法读取，请取消保留图片后重试。"
                return false
            }
        }
        var messages = Array(source.messages[..<index])
        messages.append(ChatMessage(role: .user, content: text, imageID: imageID))
        guard let id = saveBranch(of: source, messages: messages) else { return false }
        requestResponse(for: id)
        return true
    }

    private func saveBranch(of source: Conversation, messages: [ChatMessage]) -> UUID? {
        // Fresh identities keep edits and search targets independent. Images remain shared
        // until no conversation references them; deletion already checks all profiles.
        let copies = messages.map { ChatMessage(role: $0.role, content: $0.content,
                                                createdAt: $0.createdAt, imageID: $0.imageID) }
        let branch = Conversation(title: String(source.title.prefix(75)) + " · 分支",
                                  messages: copies, updatedAt: Date(), profileID: activeProfileID)
        let candidate = [branch] + allConversations
        do {
            try JSONEncoder().encode(candidate).write(to: conversationsURL, options: .atomic)
        } catch {
            errorMessage = "分支保存失败，尚未发送消息：\(error.localizedDescription)"
            return nil
        }
        allConversations = candidate
        refreshConversations()
        selectedID = branch.id
        rememberSelection()
        return branch.id
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
            do { imageID = try ImageAttachmentStore.save(imageData, directory: attachmentDirectory) }
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
            if let imageID { ImageAttachmentStore.remove(imageID, directory: attachmentDirectory) }
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
                let reply = try await HermesClient(settings: connection, sessionConfiguration: sessionConfiguration, attachmentDirectory: attachmentDirectory).stream(
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

    private func removeUnusedImages(_ candidates: Set<UUID>) {
        let retained = Set(allConversations.flatMap { $0.messages.compactMap(\.imageID) })
        for id in candidates.subtracting(retained) { ImageAttachmentStore.remove(id, directory: attachmentDirectory) }
    }

    private func refreshConversations() {
        conversations = allConversations.filter { $0.profileID == activeProfileID }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.updatedAt > $1.updatedAt
            }
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

    enum MessageLibraryError: LocalizedError {
        case missing, busy, noteTooLong, notBookmarked, draftTooLong
        var errorDescription: String? {
            switch self {
            case .missing: "这条消息已删除或不属于当前连接。"
            case .busy: "请先停止回复或等待完成，再回到原文。"
            case .noteTooLong: "收藏备注最多 2,000 字符。"
            case .notBookmarked: "这条消息尚未收藏，请先收藏后再添加备注。"
            case .draftTooLong: "引用后草稿超过 100,000 字符，请先缩短草稿。"
            }
        }
    }
}
