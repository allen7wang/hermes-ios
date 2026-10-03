import Foundation

enum SessionStreamEvent {
    case started(String)
    case delta(String)
    case progress(String)
    case commentary(String)
    case approval(RemoteApproval)
    case sessionChanged(String)
}

struct RemoteApproval: Identifiable, Decodable {
    let runID: String
    let requestID: String?
    let command: String?
    let description: String?
    let choices: [String]?

    var id: String { requestID ?? (runID + ":" + (command ?? description ?? "")) }
    var allowsOnce: Bool { choices?.contains("once") ?? true }

    enum CodingKeys: String, CodingKey {
        case command, description, choices
        case runID = "run_id"
        case requestID = "request_id"
    }
}

struct SessionStreamResult {
    let sessionID: String
    let content: String
}

// Terminal run status, rather than an assistant text event, decides whether a turn succeeded.
struct SessionStreamDecoder {
    private var sessionID: String
    private var deltas = ""
    private var finalContent: String?
    private(set) var result: SessionStreamResult?

    init(sessionID: String) { self.sessionID = sessionID }

    mutating func consume(_ frame: SSEFrame) throws -> [SessionStreamEvent] {
        guard let name = frame.event else { return [] }
        if name == "approval.request" {
            return [.approval(try JSONDecoder().decode(RemoteApproval.self, from: Data(frame.data.utf8)))]
        }
        let supported = ["run.started", "assistant.delta", "assistant.completed", "assistant.commentary",
                         "tool.started", "tool.completed", "tool.failed", "run.completed", "run.failed",
                         "run.cancelled", "run.interrupted", "error", "done"]
        guard supported.contains(name) else { return [] }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(frame.data.utf8))
        var events: [SessionStreamEvent] = []
        if let id = payload.sessionID, id != sessionID {
            sessionID = id
            events.append(.sessionChanged(id))
        }
        switch name {
        case "run.started":
            if let id = payload.runID { events.append(.started(id)) }
        case "assistant.delta":
            if let delta = payload.delta {
                deltas += delta
                events.append(.delta(delta))
            }
        case "assistant.commentary":
            if let text = payload.text { events.append(.commentary(text)) }
        case "tool.started": events.append(.progress("正在运行：\(payload.toolName ?? "工具")"))
        case "tool.completed": events.append(.progress("工具已完成：\(payload.toolName ?? "工具")"))
        case "tool.failed": events.append(.progress("工具运行失败：\(payload.toolName ?? "工具")"))
        case "assistant.completed": finalContent = payload.content
        case "run.completed":
            guard payload.completed != false, payload.partial != true, payload.interrupted != true else {
                throw ClientError.sessionFailed(payload.turnExitReason ?? "回复未完成")
            }
            let content = finalContent ?? deltas
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClientError.emptyResponse
            }
            result = SessionStreamResult(sessionID: sessionID, content: content)
        case "run.failed": throw ClientError.sessionFailed(payload.turnExitReason ?? payload.message ?? "服务端执行失败")
        case "run.cancelled", "run.interrupted": throw ClientError.sessionCancelled
        case "error": throw ClientError.sessionFailed(payload.message ?? "服务端执行失败")
        case "done":
            if result == nil { throw ClientError.incompleteStream }
        default: break
        }
        return events
    }

    private struct Payload: Decodable {
        let runID: String?
        let sessionID: String?
        let delta: String?
        let content: String?
        let text: String?
        let toolName: String?
        let message: String?
        let completed: Bool?
        let partial: Bool?
        let interrupted: Bool?
        let turnExitReason: String?

        enum CodingKeys: String, CodingKey {
            case delta, content, text, message, completed, partial, interrupted
            case runID = "run_id"
            case sessionID = "session_id"
            case toolName = "tool_name"
            case turnExitReason = "turn_exit_reason"
        }
    }
}
