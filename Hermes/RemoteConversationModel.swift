import Foundation

@MainActor
final class RemoteConversationModel: ObservableObject {
    private struct ActiveKey: Hashable {
        let profileID: UUID?
        let serverURL: String
        let sessionID: String
    }

    private static var activeModels: [ActiveKey: RemoteConversationModel] = [:]

    static func open(session: RemoteSession, client: HermesClient, draftStore: DraftStore?) -> RemoteConversationModel {
        let key = ActiveKey(profileID: client.settings.profileID,
                            serverURL: client.settings.serverURL, sessionID: session.id)
        return activeModels[key] ?? RemoteConversationModel(session: session, client: client, draftStore: draftStore)
    }

    static func hasActiveRun(profileID: UUID) -> Bool {
        activeModels.keys.contains { $0.profileID == profileID }
    }

    @Published private(set) var session: RemoteSession
    @Published private(set) var messages: [RemoteMessage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var hasOlderMessages = false
    @Published private(set) var isSending = false
    @Published private(set) var isStopping = false
    @Published private(set) var approvalBusy = false
    @Published private(set) var approvals: [RemoteApproval] = []
    @Published private(set) var transientInput: String?
    @Published private(set) var pendingImage: Data?
    @Published private(set) var transientImage: Data?
    @Published private(set) var streamedReply = ""
    @Published private(set) var progress = ""
    @Published var errorMessage: String?
    @Published var draft = "" {
        didSet {
            guard !draftAlreadyPersisted else { return }
            do { try draftStore?.set(draft, for: draftKey) }
            catch { errorMessage = "草稿保存失败：\(error.localizedDescription)" }
        }
    }

    let client: HermesClient
    private let draftStore: DraftStore?
    private var draftAlreadyPersisted = false
    private var activeSessionID: String {
        didSet {
            guard oldValue != activeSessionID else { return }
            do {
                try draftStore?.move(from: DraftStore.remoteKey(settings: client.settings, sessionID: oldValue), to: draftKey)
                if let draftStore { draft = draftStore.text(for: draftKey) }
            } catch { errorMessage = "草稿保存失败：\(error.localizedDescription)" }
            if isSending { registerActiveRun() }
        }
    }
    private var draftKey: String { DraftStore.remoteKey(settings: client.settings, sessionID: activeSessionID) }
    private var nextMessageOffset = 0
    private var runID: String?
    private var sendTask: Task<Void, Never>?
    private var revisionOverridesRestore = false

    var visibleMessages: [RemoteMessage] { messages.filter(\.isVisible) }
    var canSend: Bool { !isSending && !isLoading && !isLoadingOlder }

    init(session: RemoteSession, client: HermesClient, draftStore: DraftStore? = nil) {
        self.session = session
        self.client = client
        activeSessionID = session.id
        self.draftStore = draftStore
        draft = draftStore?.text(for: DraftStore.remoteKey(settings: client.settings, sessionID: session.id)) ?? ""
    }

    func applyPrompt(_ rendered: String, mode: PromptDraftMode) throws {
        guard let draftStore else { throw AppModel.ProfileError.storageUnavailable }
        let next = try PromptRendering.draft(current: draft, rendered: rendered, mode: mode)
        try draftStore.set(next, for: draftKey)
        draftAlreadyPersisted = true
        defer { draftAlreadyPersisted = false }
        draft = next
    }

    func reload() async {
        guard canSend else { return }
        isLoading = true
        defer { isLoading = false }
        do { try await refreshLatest(); progress = "" }
        catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    func loadOlder() async {
        guard canSend, hasOlderMessages else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await client.sessionMessagePage(activeSessionID, offset: nextMessageOffset)
            let known = Set(messages.map(\.id))
            messages = page.data.filter { !known.contains($0.id) } + messages
            nextMessageOffset += page.pagination?.returned ?? page.data.count
            hasOlderMessages = page.hasMore
            if let id = page.sessionID { activeSessionID = id }
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    func attachImage(_ original: Data) {
        guard canSend else {
            errorMessage = "正在读取或发送，请稍后再添加图片。"
            return
        }
        do { pendingImage = try ImageAttachmentStore.prepare(original) }
        catch { errorMessage = error.localizedDescription }
    }

    func removePendingImage() {
        pendingImage = nil
    }

    @discardableResult
    func send(_ rawInput: String) -> Bool {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageData = pendingImage
        guard canSend, !input.isEmpty || imageData != nil else { return false }
        let sessionAtSend = activeSessionID
        let knownIDs = Set(messages.map(\.id))
        pendingImage = nil
        draft = ""
        isSending = true
        isStopping = false
        transientInput = input.isEmpty ? nil : input
        transientImage = imageData
        streamedReply = ""
        progress = "Hermes 正在思考…"
        approvals = []
        runID = nil
        registerActiveRun()
        sendTask = Task {
            defer {
                isSending = false
                isStopping = false
                // A session SSE disconnect interrupts its run on the server. An observed
                // approval cannot be resumed once this stream ends, even on network failure.
                for approval in approvals {
                    do { try InboxStore.remove(id: approval.id, profileID: client.settings.profileID) }
                    catch { errorMessage = "收件箱清理失败：\(error.localizedDescription)" }
                }
                approvals = []
                runID = nil
                sendTask = nil
                revisionOverridesRestore = false
                Self.activeModels = Self.activeModels.filter { $0.value !== self }
            }
            do {
                let result = try await client.streamSession(sessionAtSend, input: input, imageData: imageData) { [weak self] event in
                    self?.receive(event)
                }
                guard activeSessionID == sessionAtSend || activeSessionID == result.sessionID else {
                    clearTransientAttempt()
                    return
                }
                activeSessionID = result.sessionID
                streamedReply = result.content
                progress = "回复已完成"
                recordInbox(id: "finished:" + (runID ?? result.sessionID), runID: runID, kind: .finished, title: "回复已完成", detail: snippet(result.content))
                do {
                    _ = try await refreshLatest(expectedSession: result.sessionID)
                    progress = ""
                } catch {
                    errorMessage = "回复已完成，但记录刷新失败。请点按刷新。"
                }
            } catch {
                guard !Task.isCancelled else { return }
                if case ClientError.sessionCancelled = error {
                    progress = "已停止"
                    clearTransientAttempt()
                    return
                }
                recordInbox(id: "failed:" + (runID ?? sessionAtSend), runID: runID, kind: .failed, title: "回复失败", detail: snippet(error.localizedDescription))
                errorMessage = error.localizedDescription
                progress = "回复未完成，请刷新确认服务端记录"
                let applied: Bool
                do {
                    applied = try await refreshLatest(expectedSession: sessionAtSend)
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    applied = false
                }
                guard !Task.isCancelled else { return }
                let missing = missingParts(knownIDs: knownIDs, input: input, hadImage: imageData != nil, confirmed: applied)
                if activeSessionID != sessionAtSend || missing.text || missing.image {
                    restoreUnsentAttempt(
                        input: missing.text || !applied ? input : "",
                        imageData: missing.image || !applied ? imageData : nil
                    )
                }
            }
        }
        return true
    }

    @discardableResult
    func stop() async -> Bool {
        guard isSending, !isStopping else { return false }
        guard let runID else {
            pendingImage = transientImage
            sendTask?.cancel()
            progress = "已取消连接，请刷新确认记录"
            return true
        }
        isStopping = true
        do {
            try await client.stopRun(runID)
            progress = "正在停止…"
            return true
        } catch {
            isStopping = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func stopAndPlaceInDraft(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, await stop() else { return false }
        if isSending { revisionOverridesRestore = true }
        draft = trimmed
        return true
    }

    func resolve(_ approval: RemoteApproval, choice: String) async {
        guard !approvalBusy, approvals.contains(where: { $0.id == approval.id }) else { return }
        approvalBusy = true
        defer { approvalBusy = false }
        do {
            try await client.resolveApproval(approval, choice: choice)
            do { try InboxStore.remove(id: approval.id, profileID: client.settings.profileID) }
            catch { errorMessage = "审批已提交，但收件箱清理失败：\(error.localizedDescription)" }
            approvals.removeAll { $0.id == approval.id }
            progress = approvalProgress(for: choice)
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(to rawTitle: String) async -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !title.isEmpty else { return false }
        do {
            session = try await client.renameSession(activeSessionID, title: title)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func delete() async -> Bool {
        guard canSend else { return false }
        do {
            try await client.deleteSession(activeSessionID)
            draft = ""
            return true
        }
        catch { errorMessage = error.localizedDescription; return false }
    }

    private func refreshLatest() async throws {
        _ = try await refreshLatest(expectedSession: activeSessionID)
    }

    @discardableResult
    private func refreshLatest(expectedSession: String) async throws -> Bool {
        guard activeSessionID == expectedSession else { return false }
        let page = try await client.sessionMessagePage(expectedSession)
        try Task.checkCancellation()
        guard activeSessionID == expectedSession else { return false }
        messages = page.data
        nextMessageOffset = page.pagination?.returned ?? page.data.count
        hasOlderMessages = page.hasMore
        if let id = page.sessionID, id != activeSessionID { activeSessionID = id }
        clearTransientAttempt()
        streamedReply = ""
        return true
    }

    private struct MissingParts {
        var text = false
        var image = false
    }

    private func missingParts(knownIDs: Set<String>, input: String, hadImage: Bool, confirmed: Bool) -> MissingParts {
        guard confirmed else { return MissingParts(text: !input.isEmpty, image: hadImage) }
        let fresh = messages.filter { $0.role == "user" && !knownIDs.contains($0.id) }
        let textSaved = input.isEmpty || fresh.contains { $0.content.contains(input) }
        let imageSaved = !hadImage || fresh.contains { $0.content.contains("[screenshot]") }
        return MissingParts(text: !textSaved, image: !imageSaved)
    }

    private func restoreUnsentAttempt(input: String, imageData: Data?) {
        clearTransientAttempt()
        if !revisionOverridesRestore && !input.isEmpty {
            if draft.isEmpty { draft = input }
            else if draft != input {
                draft = input + "\n\n" + draft
                errorMessage = "发送失败：已保留原输入和你新写的草稿，请检查后再发送。"
            }
        }
        pendingImage = imageData
    }

    private func registerActiveRun() {
        let key = ActiveKey(profileID: client.settings.profileID,
                            serverURL: client.settings.serverURL, sessionID: activeSessionID)
        Self.activeModels[key] = self
    }

    private func clearTransientAttempt() {
        transientInput = nil
        transientImage = nil
    }

    private func receive(_ event: SessionStreamEvent) {
        switch event {
        case .started(let id): runID = id
        case .delta(let text): streamedReply += text
        case .progress(let text), .commentary(let text): progress = text
        case .sessionChanged(let id): activeSessionID = id
        case .approval(let approval):
            if !approvals.contains(where: { $0.id == approval.id }) {
                approvals.append(approval)
                recordInbox(
                    id: approval.id,
                    runID: approval.runID,
                    requestID: approval.requestID,
                    command: approval.command,
                    choices: approval.choices,
                    kind: .approval,
                    title: "需要审批",
                    detail: snippet(approval.description ?? approval.command ?? "等待你的决定")
                )
            }
            progress = "需要你的审批"
        }
    }

    private func approvalProgress(for choice: String) -> String {
        switch choice {
        case "deny": return "已拒绝，等待服务端继续…"
        case "session": return "已允许本次会话，正在继续…"
        case "always": return "已始终允许，正在继续…"
        default: return "已允许本次操作，正在继续…"
        }
    }

    private func recordInbox(id: String, runID: String?, requestID: String? = nil,
                             command: String? = nil, choices: [String]? = nil,
                             kind: InboxItem.Kind, title: String, detail: String) {
        do {
            try InboxStore.upsert(InboxItem(
                id: id,
                profileID: client.settings.profileID,
                sessionID: activeSessionID,
                sessionTitle: session.displayTitle,
                runID: runID,
                requestID: requestID,
                command: command,
                choices: choices,
                kind: kind,
                title: title,
                detail: detail,
                createdAt: Date()
            ))
        } catch { errorMessage = "收件箱保存失败：\(error.localizedDescription)" }
    }

    private func snippet(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "无更多说明" }
        if trimmed.count <= 160 { return trimmed }
        return String(trimmed.prefix(160))
    }
}
