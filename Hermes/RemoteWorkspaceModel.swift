import Foundation

enum RemoteJobFilter: String, CaseIterable, Identifiable {
    case all, scheduled, running, paused, attention, completed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .scheduled: return "计划中"
        case .running: return "运行中"
        case .paused: return "已暂停"
        case .attention: return "需关注"
        case .completed: return "已完成"
        }
    }

    func includes(_ job: RemoteJob) -> Bool {
        switch self {
        case .all: return true
        case .scheduled: return !job.isPaused && (job.state == "scheduled" || job.state == nil)
        case .running: return !job.isPaused && job.state == "running"
        case .paused: return job.isPaused
        case .attention: return job.needsAttention
        case .completed: return !job.isPaused && job.state == "completed"
        }
    }
}

@MainActor
final class RemoteWorkspaceModel: ObservableObject {
    @Published private(set) var sessions: [RemoteSession] = []
    @Published private(set) var jobs: [RemoteJob] = []
    @Published private(set) var isLoadingSessions = false
    @Published private(set) var isLoadingMoreSessions = false
    @Published private(set) var isLoadingJobs = false
    @Published private(set) var hasMoreSessions = false
    @Published private(set) var sessionsError: String?
    @Published private(set) var jobsError: String?
    @Published private(set) var jobDetailError: String?
    @Published private(set) var sessionsUpdatedAt: Date?
    @Published private(set) var jobsUpdatedAt: Date?
    @Published private(set) var busySessionID: String?
    @Published private(set) var busyJobID: String?
    @Published private(set) var refreshingJobID: String?
    @Published var actionError: String?
    @Published var notice: String?

    // A workspace is bound to one connection for its entire lifetime.
    let client: HermesClient
    private var sessionGeneration = 0
    private var jobGeneration = 0
    private var nextSessionOffset = 0

    var sessionActionsDisabled: Bool { isLoadingSessions || isLoadingMoreSessions || busySessionID != nil }
    var jobActionsDisabled: Bool { isLoadingJobs || busyJobID != nil || refreshingJobID != nil }

    init(client: HermesClient) { self.client = client }

    func filteredSessions(query: String, pinnedOnly: Bool) -> [RemoteSession] {
        sessions.filter { session in
            (!pinnedOnly || session.pinned == true) && Self.matches(query, in: [
                session.displayTitle, session.preview ?? "", session.source ?? "", session.id
            ])
        }
    }

    func filteredJobs(query: String, filter: RemoteJobFilter) -> [RemoteJob] {
        jobs.filter { filter.includes($0) && Self.matches(query, in: [
            $0.name, $0.prompt ?? "", $0.scheduleDisplay ?? "", $0.id
        ]) }
    }

    func reloadSessions() async {
        guard client.settings.isConfigured, busySessionID == nil else { return }
        sessionGeneration += 1
        let generation = sessionGeneration
        isLoadingSessions = true
        isLoadingMoreSessions = false
        sessionsError = nil
        defer { if generation == sessionGeneration { isLoadingSessions = false } }
        do {
            let page = try await client.sessions()
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            sessions = Self.mergeSessions([], with: page.data)
            hasMoreSessions = page.hasMore
            // Pinned sessions may be back-filled beyond the server's 50-row window.
            nextSessionOffset = 50
            sessionsUpdatedAt = Date()
        } catch {
            if generation == sessionGeneration, !Self.isCancellation(error) { sessionsError = error.localizedDescription }
        }
    }

    func loadMoreSessions() async {
        guard !sessionActionsDisabled, hasMoreSessions else { return }
        let generation = sessionGeneration
        isLoadingMoreSessions = true
        sessionsError = nil
        defer { if generation == sessionGeneration { isLoadingMoreSessions = false } }
        do {
            let page = try await client.sessions(offset: nextSessionOffset)
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            sessions = Self.mergeSessions(sessions, with: page.data)
            hasMoreSessions = page.hasMore
            nextSessionOffset += 50
            sessionsUpdatedAt = Date()
        } catch {
            if generation == sessionGeneration, !Self.isCancellation(error) { sessionsError = error.localizedDescription }
        }
    }

    func reloadJobs() async {
        guard client.settings.isConfigured, busyJobID == nil, refreshingJobID == nil else { return }
        jobGeneration += 1
        let generation = jobGeneration
        isLoadingJobs = true
        jobsError = nil
        defer { if generation == jobGeneration { isLoadingJobs = false } }
        do {
            let received = try await client.jobs()
            guard generation == jobGeneration, !Task.isCancelled else { return }
            var seen = Set<String>()
            jobs = received.filter { seen.insert($0.id).inserted }
            jobsUpdatedAt = Date()
        } catch {
            if generation == jobGeneration, !Self.isCancellation(error) { jobsError = error.localizedDescription }
        }
    }

    func refreshJob(_ id: String) async {
        guard !jobActionsDisabled else { return }
        refreshingJobID = id
        jobDetailError = nil
        defer { refreshingJobID = nil }
        do {
            let updated = try await client.job(id)
            guard !Task.isCancelled else { return }
            updateJob(updated)
        } catch {
            if !Self.isCancellation(error) { jobDetailError = error.localizedDescription }
        }
    }

    func togglePin(_ session: RemoteSession) async {
        guard !sessionActionsDisabled, session.pinned != nil else { return }
        busySessionID = session.id
        defer { busySessionID = nil }
        do {
            let updated = try await client.setSessionPinned(session.id, pinned: session.pinned != true)
            let merged = RemoteSession(id: session.id, title: updated.title ?? session.title,
                source: updated.source ?? session.source, preview: updated.preview ?? session.preview,
                lastActive: updated.lastActive ?? session.lastActive,
                messageCount: updated.messageCount ?? session.messageCount, pinned: updated.pinned)
            sessions = Self.mergeSessions(sessions, with: [merged])
        } catch { actionError = error.localizedDescription }
    }

    func createSession(title: String) async -> RemoteSession? {
        guard !sessionActionsDisabled else { return nil }
        busySessionID = "new"
        defer { busySessionID = nil }
        do {
            let created = try await client.createSession(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
            sessions = Self.mergeSessions(sessions, with: [created])
            return created
        } catch { actionError = error.localizedDescription; return nil }
    }

    func toggleJob(_ job: RemoteJob) async {
        guard !jobActionsDisabled else { return }
        busyJobID = job.id
        defer { busyJobID = nil }
        do { updateJob(try await client.setJobPaused(job.id, paused: !job.isPaused)) }
        catch { actionError = error.localizedDescription }
    }

    func runJob(_ job: RemoteJob) async {
        guard !jobActionsDisabled else { return }
        busyJobID = job.id
        notice = nil
        jobDetailError = nil
        defer { busyJobID = nil }
        do {
            try await client.runJob(job.id)
            notice = "已提交“\(job.name)”的运行请求，请刷新查看结果。"
            do { jobs = try await client.jobs(); jobsUpdatedAt = Date(); jobsError = nil }
            catch {
                let message = "运行请求已提交，但刷新失败：\(error.localizedDescription)"
                jobsError = message
                jobDetailError = message
            }
        } catch { actionError = error.localizedDescription }
    }

    @discardableResult
    func deleteJob(_ job: RemoteJob) async -> Bool {
        guard !jobActionsDisabled else { return false }
        busyJobID = job.id
        defer { busyJobID = nil }
        do {
            try await client.deleteJob(job.id)
            jobs.removeAll { $0.id == job.id }
            return true
        } catch { actionError = error.localizedDescription; return false }
    }

    private func updateJob(_ job: RemoteJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        else { jobs.append(job) }
    }

    private static func matches(_ query: String, in fields: [String]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || fields.contains { $0.localizedStandardContains(needle) }
    }

    private static func mergeSessions(_ current: [RemoteSession], with incoming: [RemoteSession]) -> [RemoteSession] {
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for session in incoming { byID[session.id] = session }
        return byID.values.sorted {
            if ($0.pinned == true) != ($1.pinned == true) { return $0.pinned == true }
            if ($0.lastActive ?? 0) != ($1.lastActive ?? 0) { return ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }
            return $0.id < $1.id
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
