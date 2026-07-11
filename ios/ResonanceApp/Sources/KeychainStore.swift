import Foundation
import os
import Security

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "KeychainStore")

enum KeychainStore {
    static let itemAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    static func accountKey(for key: String) -> String {
        "\(AppConfig.keychainNamespace).\(key)"
    }

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let accountKey = accountKey(for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: itemAccessibility
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            logger.error("Keychain delete error for \(accountKey): OSStatus \(deleteStatus)")
        }

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess {
            logger.error("Keychain add error for \(accountKey): OSStatus \(addStatus)")
        }
    }

    static func get(_ key: String) -> String? {
        let accountKey = accountKey(for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return String(bytes: data, encoding: .utf8)
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain get error for \(accountKey): OSStatus \(status)")
        }
        return nil
    }

    static func remove(_ key: String) {
        let accountKey = accountKey(for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountKey
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain remove error for \(accountKey): OSStatus \(status)")
        }
    }
}
