import Foundation
import Security

enum KeychainStore {
    private static let service = "com.a7w.hermes.api"
    static func readKey(account: String = "api-server-key") -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    static func saveKey(_ key: String, account: String = "api-server-key") throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.saveFailed(status)
            }
            return
        }

        let data = Data(key.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.saveFailed(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status): "无法安全保存密钥（\(status)）。"
            }
        }
    }
}

protocol CredentialStore {
    func read(account: String) -> String
    func save(_ key: String, account: String) throws
}

struct SystemCredentialStore: CredentialStore {
    func read(account: String) -> String { KeychainStore.readKey(account: account) }
    func save(_ key: String, account: String) throws { try KeychainStore.saveKey(key, account: account) }
}
