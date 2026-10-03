import Foundation

enum ChatStreamEvent {
    case delta(String)
    case tool(ToolProgress)
}

struct ToolProgress: Decodable {
    let tool: String?
    let emoji: String?
    let label: String?
    let status: String?
}

struct HermesClient {
    let settings: ConnectionSettings
    let sessionConfiguration: URLSessionConfiguration

    init(settings: ConnectionSettings, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.settings = settings
        self.sessionConfiguration = sessionConfiguration
    }

    private var rootURL: URL {
        get throws {
            let raw = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var parts = URLComponents(string: raw),
                  let scheme = parts.scheme?.lowercased(),
                  let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil else {
                throw ClientError.invalidURL
            }

            let octets = host.split(separator: ".").compactMap { Int($0) }
            let private172 = octets.count == 4 && octets[0] == 172 && (16...31).contains(octets[1])
            let localHost = host == "localhost" || host == "127.0.0.1" ||
                host.hasSuffix(".local") || host.hasPrefix("192.168.") ||
                host.hasPrefix("10.") || private172
            guard scheme == "https" || (scheme == "http" && localHost) else {
                throw ClientError.insecureURL
            }

            var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == "v1" { path = "" }
            else if path.hasSuffix("/v1") { path.removeLast(3) }
            parts.path = path.isEmpty ? "" : "/" + path
            guard let url = parts.url else { throw ClientError.invalidURL }
            return url
        }
    }

    func availableModels() async throws -> [String] {
        let url = try endpoint("v1", "models")
        let data = try await perform(url: url)
        let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return response.data.map(\.id)
    }

    func sessions(offset: Int = 0) async throws -> RemoteSessionPage {
        var components = URLComponents(url: try endpoint("api", "sessions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "include_children", value: "true")
        ]
        return try await request(RemoteSessionPage.self, url: components.url!)
    }

    func sessionMessages(_ id: String) async throws -> [RemoteMessage] {
        try await sessionMessagePage(id).data
    }

    func sessionMessagePage(_ id: String, offset: Int = 0) async throws -> RemoteMessagesResponse {
        var components = URLComponents(url: try endpoint("api", "sessions", id, "messages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "include_compacted", value: "true"),
            URLQueryItem(name: "inline_images", value: "false")
        ]
        return try await request(RemoteMessagesResponse.self, url: components.url!)
    }

    func createSession(title: String) async throws -> RemoteSession {
        let response = try await request(RemoteSessionResponse.self, url: endpoint("api", "sessions"),
                                         method: "POST", body: ["title": title])
        return response.session
    }

    func renameSession(_ id: String, title: String) async throws -> RemoteSession {
        let response: RemoteSessionResponse = try await request(
            RemoteSessionResponse.self,
            url: endpoint("api", "sessions", id),
            method: "PATCH",
            body: ["title": title]
        )
        return response.session
    }

    func deleteSession(_ id: String) async throws {
        let response: RemoteSessionDeleteResponse = try await request(
            RemoteSessionDeleteResponse.self,
            url: endpoint("api", "sessions", id),
            method: "DELETE"
        )
        guard response.deleted else { throw ClientError.invalidResponse }
    }

    func jobs() async throws -> [RemoteJob] {
        var components = URLComponents(url: try endpoint("api", "jobs"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "include_disabled", value: "true")]
        let response: RemoteJobsResponse = try await request(RemoteJobsResponse.self, url: components.url!)
        return response.jobs
    }

    func createJob(name: String, schedule: String, prompt: String) async throws -> RemoteJob {
        let response: RemoteJobResponse = try await request(
            RemoteJobResponse.self,
            url: endpoint("api", "jobs"),
            method: "POST",
            body: ["name": name, "schedule": schedule, "prompt": prompt, "deliver": "local"]
        )
        return response.job
    }

    func setJobPaused(_ id: String, paused: Bool) async throws -> RemoteJob {
        let response: RemoteJobResponse = try await request(
            RemoteJobResponse.self,
            url: endpoint("api", "jobs", id, paused ? "pause" : "resume"),
            method: "POST"
        )
        return response.job
    }

    func updateJob(_ id: String, fields: [String: String]) async throws -> RemoteJob {
        let response = try await request(RemoteJobResponse.self, url: endpoint("api", "jobs", id),
                                         method: "PATCH", body: fields)
        return response.job
    }

    func deleteJob(_ id: String) async throws {
        let response = try await request(JobDeleteResponse.self, url: endpoint("api", "jobs", id), method: "DELETE")
        guard response.ok else { throw ClientError.invalidResponse }
    }

    func stopRun(_ id: String) async throws {
        _ = try await request(RunStopResponse.self, url: endpoint("v1", "runs", id, "stop"), method: "POST")
    }

    func resolveApproval(_ approval: RemoteApproval, choice: String) async throws {
        var body = ["choice": choice]
        if let requestID = approval.requestID { body["request_id"] = requestID }
        let response = try await request(ApprovalResponse.self,
            url: endpoint("v1", "runs", approval.runID, "approval"), method: "POST", body: body)
        guard response.resolved > 0 else { throw ClientError.invalidResponse }
    }

    func streamSession(_ id: String, input: String, onEvent: (SessionStreamEvent) async -> Void) async throws -> SessionStreamResult {
        var urlRequest = authorizedRequest(url: try endpoint("api", "sessions", id, "chat", "stream"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The server owns this transcript and its configured model; send only the new turn.
        urlRequest.httpBody = try JSONEncoder().encode(["input": input])
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 300 { break }
            }
            throw ClientError.server(response.statusCode, String(decoding: body, as: UTF8.self))
        }
        var parser = SSEParser()
        var decoder = SessionStreamDecoder(sessionID: id)
        var lineBytes: [UInt8] = []
        for try await byte in bytes {
            try Task.checkCancellation()
            guard byte == 10 else {
                lineBytes.append(byte)
                if lineBytes.count > 1_000_000 { throw ClientError.invalidStream }
                continue
            }
            if lineBytes.last == 13 { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            if let frame = parser.consume(line) {
                for event in try decoder.consume(frame) { await onEvent(event) }
                if let result = decoder.result { return result }
            }
        }
        if !lineBytes.isEmpty {
            _ = parser.consume(String(decoding: lineBytes, as: UTF8.self))
        }
        if let frame = parser.flush() {
            for event in try decoder.consume(frame) { await onEvent(event) }
        }
        guard let result = decoder.result else { throw ClientError.incompleteStream }
        return result
    }

    func runJob(_ id: String) async throws {
        // The run endpoint acknowledges scheduling; completion is reported by a later refresh.
        _ = try await request(RemoteJobResponse.self,
                              url: endpoint("api", "jobs", id, "run"), method: "POST")
    }

    func stream(
        messages: [ChatMessage],
        onEvent: (ChatStreamEvent) async -> Void
    ) async throws -> String {
        let url = try endpoint("v1", "chat", "completions")
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            CompletionRequest(
                model: settings.model.isEmpty ? "hermes-agent" : settings.model,
                messages: try messages.map(CompletionMessage.init),
                stream: true
            )
        )

        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count >= 300 { break }
            }
            throw ClientError.server(response.statusCode, String(body.prefix(300)))
        }

        var parser = SSEParser()
        var text = ""
        var finishReason: String?
        var receivedDone = false
        var lineBytes: [UInt8] = []
        for try await byte in bytes {
            try Task.checkCancellation()
            guard byte == 10 else {
                lineBytes.append(byte)
                if lineBytes.count > 1_000_000 { throw ClientError.invalidStream }
                continue
            }
            if lineBytes.last == 13 { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            guard let frame = parser.consume(line) else { continue }
            if frame.data == "[DONE]" {
                receivedDone = true
                break
            }
            if frame.event == "hermes.tool.progress" {
                if let progress = try? JSONDecoder().decode(ToolProgress.self, from: Data(frame.data.utf8)) {
                    await onEvent(.tool(progress))
                }
                continue
            }
            guard frame.event == nil || frame.event == "message" ||
                    frame.event == "chat.completion.chunk" else { continue }
            let chunk = try JSONDecoder().decode(CompletionChunk.self, from: Data(frame.data.utf8))
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                text += delta
                await onEvent(.delta(delta))
            }
            if let reason = chunk.choices.first?.finishReason { finishReason = reason }
        }

        guard receivedDone else { throw ClientError.incompleteStream }
        if let finishReason, finishReason != "stop" {
            throw ClientError.streamFailed(finishReason)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.emptyResponse
        }
        return text
    }

    private func endpoint(_ segments: String...) throws -> URL {
        segments.reduce(try rootURL) { $0.appendingPathComponent($1) }
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    private func perform(url: URL) async throws -> Data {
        try await perform(request: authorizedRequest(url: url))
    }

    private func request<T: Decodable>(_ type: T.Type, url: URL, method: String = "GET", body: [String: String]? = nil) async throws -> T {
        var urlRequest = authorizedRequest(url: url)
        urlRequest.httpMethod = method
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(body)
        }
        let data = try await perform(request: urlRequest)
        return try JSONDecoder().decode(type, from: data)
    }

    private func perform(request: URLRequest) async throws -> Data {
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.server(response.statusCode, String(body.prefix(300)))
        }
        return data
    }
}

private struct ModelsResponse: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct JobDeleteResponse: Decodable { let ok: Bool }
private struct RunStopResponse: Decodable { let status: String }
private struct ApprovalResponse: Decodable { let resolved: Int }

private struct CompletionRequest: Encodable {
    let model: String
    let messages: [CompletionMessage]
    let stream: Bool
}

private struct CompletionMessage: Encodable {
    let role: String
    let content: Content

    init(_ message: ChatMessage) throws {
        role = message.role.rawValue
        if let imageID = message.imageID {
            let image = try ImageAttachmentStore.load(imageID)
            let imageURL = "data:image/jpeg;base64," + image.base64EncodedString()
            var parts: [Part] = []
            if !message.content.isEmpty { parts.append(.text(message.content)) }
            parts.append(.image(imageURL))
            content = .parts(parts)
        } else {
            content = .text(message.content)
        }
    }

    enum Content: Encodable {
        case text(String)
        case parts([Part])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value): try container.encode(value)
            case .parts(let value): try container.encode(value)
            }
        }
    }

    struct Part: Encodable {
        struct ImageURL: Encodable { let url: String }
        let type: String
        let text: String?
        let imageURL: ImageURL?

        static func text(_ value: String) -> Part {
            Part(type: "text", text: value, imageURL: nil)
        }

        static func image(_ value: String) -> Part {
            Part(type: "image_url", text: nil, imageURL: ImageURL(url: value))
        }

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }
}

private struct CompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

enum ClientError: LocalizedError {
    case invalidURL
    case insecureURL
    case invalidResponse
    case emptyResponse
    case incompleteStream
    case invalidStream
    case streamFailed(String)
    case sessionFailed(String)
    case sessionCancelled
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入完整的服务地址，例如 https://hermes.example.com/v1。"
        case .insecureURL: "远程服务请使用 HTTPS；HTTP 仅用于局域网地址。"
        case .invalidResponse: "服务没有返回有效的 HTTP 响应。"
        case .emptyResponse: "Hermes 返回了空内容。"
        case .incompleteStream: "连接在回复完成前中断，请重试。"
        case .invalidStream: "Hermes 返回的流式数据过大或无效。"
        case .streamFailed(let reason): "Hermes 未完成回复（\(reason)），请重试。"
        case .sessionFailed(let reason): "服务端回复未完成：\(reason)。请刷新会话确认记录。"
        case .sessionCancelled: "服务端已停止本次回复。"
        case .server(let code, let message): "服务错误 \(code)：\(message)"
        }
    }
}
