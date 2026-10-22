import Foundation

enum RemoteRefreshInterval: Int, CaseIterable, Identifiable {
    case off = 0, thirty = 30, sixty = 60, twoMinutes = 120
    var id: Int { rawValue }
    var title: String { self == .off ? "手动刷新" : "每 \(rawValue) 秒" }

    func delay(afterFailures failures: Int) -> Int {
        guard self != .off else { return 0 }
        return min(300, rawValue * (1 << min(3, max(0, failures))))
    }
}

struct RemoteJobDraft: Equatable {
    let name: String
    let prompt: String
    let schedule: String

    init(copying job: RemoteJob) {
        name = String(job.name.prefix(195)) + " · 副本"
        prompt = job.prompt ?? ""
        // An old one-shot timestamp must never silently schedule a new task.
        schedule = job.schedule?.kind == "once" ? "" : job.editableSchedule
    }
}

struct RemoteJobOverview {
    let running: Int
    let attention: Int
    let paused: Int
    init(_ jobs: [RemoteJob]) {
        running = jobs.filter { RemoteJobFilter.running.includes($0) }.count
        attention = jobs.filter(\.needsAttention).count
        paused = jobs.filter(\.isPaused).count
    }
}
