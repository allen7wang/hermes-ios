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
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
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
        case .server(let code, let message): "服务错误 \(code)：\(message)"
        }
    }
}
