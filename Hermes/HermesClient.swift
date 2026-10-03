import Foundation

struct HermesClient {
    let settings: ConnectionSettings

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

            // Keep HTTP available for a local gateway. Remote connections require HTTPS.
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

    func complete(messages: [ChatMessage]) async throws -> String {
        let url = try endpoint("v1", "chat", "completions")
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CompletionRequest(
                model: settings.model.isEmpty ? "hermes-agent" : settings.model,
                messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) },
                stream: false
            )
        )
        let data = try await perform(request: request)
        let response = try JSONDecoder().decode(CompletionResponse.self, from: data)
        guard let content = response.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.emptyResponse
        }
        return content
    }

    private func endpoint(_ segments: String...) throws -> URL {
        segments.reduce(try rootURL) { $0.appendingPathComponent($1) }
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        return request
    }

    private func perform(url: URL) async throws -> Data {
        try await perform(request: authorizedRequest(url: url))
    }

    private func perform(request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
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

private struct CompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let stream: Bool
}

private struct CompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

enum ClientError: LocalizedError {
    case invalidURL
    case insecureURL
    case invalidResponse
    case emptyResponse
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入完整的服务地址，例如 https://hermes.example.com/v1。"
        case .insecureURL: "远程服务请使用 HTTPS；HTTP 仅用于局域网地址。"
        case .invalidResponse: "服务没有返回有效的 HTTP 响应。"
        case .emptyResponse: "Hermes 返回了空内容。"
        case .server(let code, let message): "服务错误 \(code)：\(message)"
        }
    }
}
