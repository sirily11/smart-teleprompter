import Foundation
import Security

/// Device-only storage: credentials do not sync through iCloud or migrate in backups.
struct NotionCredentialStore {
    var service = "rxlab.smart-teleprompter.notion"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "access-token",
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw StorageError()
        }
        return token
    }

    func save(_ token: String) throws {
        guard !token.isEmpty else { throw StorageError() }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StorageError() }
        } else if status != errSecSuccess {
            throw StorageError()
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError() }
    }

    private struct StorageError: LocalizedError {
        var errorDescription: String? {
            "Couldn’t access the saved Notion connection on this device. Please try again."
        }
    }
}
