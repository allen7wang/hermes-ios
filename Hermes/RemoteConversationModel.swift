import Foundation

@MainActor
final class RemoteConversationModel: ObservableObject {
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
    @Published private(set) var streamedReply = ""
    @Published private(set) var progress = ""
    @Published var errorMessage: String?

    let client: HermesClient
    private var activeSessionID: String
    private var nextMessageOffset = 0
    private var runID: String?
    private var sendTask: Task<Void, Never>?

    var visibleMessages: [RemoteMessage] { messages.filter(\.isVisible) }
    var canSend: Bool { !isSending && !isLoading && !isLoadingOlder }

    init(session: RemoteSession, client: HermesClient) {
        self.session = session
        self.client = client
        activeSessionID = session.id
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

    @discardableResult
    func send(_ rawInput: String) -> Bool {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !input.isEmpty else { return false }
        isSending = true
        isStopping = false
        transientInput = input
        streamedReply = ""
        progress = "Hermes 正在思考…"
        approvals = []
        runID = nil
        sendTask = Task {
            defer {
                isSending = false
                isStopping = false
                approvals = []
                runID = nil
                sendTask = nil
            }
            do {
                let result = try await client.streamSession(activeSessionID, input: input) { [weak self] event in
                    self?.receive(event)
                }
                activeSessionID = result.sessionID
                streamedReply = result.content
                progress = "回复已完成"
                do { try await refreshLatest(); progress = "" }
                catch { errorMessage = "回复已完成，但记录刷新失败。请点按刷新。" }
            } catch {
                guard !Task.isCancelled else { return }
                if case ClientError.sessionCancelled = error {
                    progress = "已停止"
                } else {
                    errorMessage = error.localizedDescription
                    progress = "回复未完成，请刷新确认服务端记录"
                }
                // A failed connection may still have persisted the turn; never resend automatically.
                try? await refreshLatest()
            }
        }
        return true
    }

    func stop() async {
        guard isSending, !isStopping else { return }
        guard let runID else {
            sendTask?.cancel()
            progress = "已取消连接，请刷新确认记录"
            return
        }
        isStopping = true
        do {
            try await client.stopRun(runID)
            progress = "正在停止…"
        } catch {
            isStopping = false
            errorMessage = error.localizedDescription
        }
    }

    func resolve(_ approval: RemoteApproval, choice: String) async {
        guard !approvalBusy, approvals.contains(where: { $0.id == approval.id }) else { return }
        approvalBusy = true
        defer { approvalBusy = false }
        do {
            try await client.resolveApproval(approval, choice: choice)
            approvals.removeAll { $0.id == approval.id }
            progress = choice == "deny" ? "已拒绝，等待服务端继续…" : "已允许本次操作，正在继续…"
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
        do { try await client.deleteSession(activeSessionID); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    func close() {
        if let runID {
            let client = client
            Task { try? await client.stopRun(runID) }
        }
        sendTask?.cancel()
    }

    private func refreshLatest() async throws {
        let page = try await client.sessionMessagePage(activeSessionID)
        try Task.checkCancellation()
        messages = page.data
        nextMessageOffset = page.pagination?.returned ?? page.data.count
        hasOlderMessages = page.hasMore
        if let id = page.sessionID { activeSessionID = id }
        transientInput = nil
        streamedReply = ""
    }

    private func receive(_ event: SessionStreamEvent) {
        switch event {
        case .started(let id): runID = id
        case .delta(let text): streamedReply += text
        case .progress(let text), .commentary(let text): progress = text
        case .sessionChanged(let id): activeSessionID = id
        case .approval(let approval):
            if !approvals.contains(where: { $0.id == approval.id }) { approvals.append(approval) }
            progress = "需要你的审批"
        }
    }
}
