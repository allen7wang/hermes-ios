import Foundation

enum PairingPayloadError: LocalizedError, Equatable {
    case invalid
    case unknownVersion
    case emptyURL
    case emptyKey

    var errorDescription: String? {
        switch self {
        case .invalid: "配对码无效。"
        case .unknownVersion: "配对码版本不受支持。"
        case .emptyURL: "配对码缺少服务地址。"
        case .emptyKey: "配对码缺少密钥。"
        }
    }
}

/// Local QR payload only. There is no gateway pairing endpoint.
/// UTF-8 JSON: {"v":1,"name":"...","url":"...","key":"..."} with no extra fields.
struct PairingPayload: Equatable {
    static let version = 1
    static let defaultName = "扫码连接"
    static let maxBytes = 8_192

    var name: String
    var url: String
    var key: String

    static func encode(name: String, url: String, key: String) throws -> String {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw PairingPayloadError.emptyURL }
        guard !key.isEmpty else { throw PairingPayloadError.emptyKey }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadName = trimmedName.isEmpty ? defaultName : trimmedName
        let nameJSON = try quoted(payloadName)
        let urlJSON = try quoted(url)
        let keyJSON = try quoted(key)
        return "{\"v\":\(version),\"name\":\(nameJSON),\"url\":\(urlJSON),\"key\":\(keyJSON)}"
    }

    static func decode(_ raw: String) throws -> PairingPayload {
        guard raw.utf8.count <= maxBytes else { throw PairingPayloadError.invalid }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PairingPayloadError.invalid
        }
        let allowed: Set<String> = ["v", "name", "url", "key"]
        guard Set(object.keys).isSubset(of: allowed),
              object["v"] != nil, object["url"] != nil, object["key"] != nil else {
            throw PairingPayloadError.invalid
        }
        guard let version = strictInt(object["v"]) else { throw PairingPayloadError.invalid }
        guard version == self.version else { throw PairingPayloadError.unknownVersion }
        guard let urlValue = object["url"] as? String,
              let keyValue = object["key"] as? String else {
            throw PairingPayloadError.invalid
        }
        let url = urlValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw PairingPayloadError.emptyURL }
        guard !key.isEmpty else { throw PairingPayloadError.emptyKey }
        let name = try decodedName(object["name"])
        return PairingPayload(name: name, url: url, key: key)
    }

    private static func decodedName(_ value: Any?) throws -> String {
        if value == nil { return defaultName }
        guard let given = value as? String else { throw PairingPayloadError.invalid }
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    private static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func quoted(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        guard let text = String(data: data, encoding: .utf8), text.count >= 2 else {
            throw PairingPayloadError.invalid
        }
        return String(text.dropFirst().dropLast())
    }
}
