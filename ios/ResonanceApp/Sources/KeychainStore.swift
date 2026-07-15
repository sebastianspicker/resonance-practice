import Foundation
import os
import Security

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "KeychainStore")

enum KeychainStore {
    static let itemAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    static func accountKey(for key: String) -> String {
        "\(AppConfig.keychainNamespace).\(key)"
    }

    static func store(_ value: String, for key: String) throws {
        try store(Data(value.utf8), for: key)
        guard try read(key) == value else {
            throw KeychainStoreError.valueVerificationFailed(key)
        }
    }

    static func store(_ data: Data, for key: String) throws {
        let accountKey = accountKey(for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountKey
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: itemAccessibility
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let addQuery = query.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.operationFailed("add", key: key, status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainStoreError.operationFailed("update", key: key, status: updateStatus)
        }
        guard try readData(key) == data else {
            throw KeychainStoreError.valueVerificationFailed(key)
        }
    }

    static func read(_ key: String) throws -> String? {
        guard let data = try readData(key) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidStoredValue(key)
        }
        return value
    }

    static func readData(_ key: String) throws -> Data? {
        let accountKey = accountKey(for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainStoreError.invalidStoredValue(key)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.operationFailed("read", key: key, status: status)
        }
    }

    static func removeStoredValue(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountKey(for: key)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed("remove", key: key, status: status)
        }
        guard try read(key) == nil else {
            throw KeychainStoreError.removalVerificationFailed(key)
        }
    }

    static func set(_ value: String, for key: String) {
        do {
            try store(value, for: key)
        } catch {
            logger.error("Keychain store error for \(accountKey(for: key)): \(error.localizedDescription)")
        }
    }

    static func get(_ key: String) -> String? {
        do {
            return try read(key)
        } catch {
            logger.error("Keychain get error for \(accountKey(for: key)): \(error.localizedDescription)")
            return nil
        }
    }

    static func remove(_ key: String) {
        do {
            try removeStoredValue(for: key)
        } catch {
            logger.error("Keychain remove error for \(accountKey(for: key)): \(error.localizedDescription)")
        }
    }
}

enum KeychainStoreError: LocalizedError {
    case operationFailed(String, key: String, status: OSStatus)
    case invalidStoredValue(String)
    case valueVerificationFailed(String)
    case removalVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .operationFailed(operation, key, status):
            return "Keychain \(operation) failed for \(key) (OSStatus \(status))."
        case let .invalidStoredValue(key):
            return "Keychain value for \(key) is invalid."
        case let .valueVerificationFailed(key):
            return "Keychain value for \(key) could not be verified."
        case let .removalVerificationFailed(key):
            return "Keychain value for \(key) could not be removed."
        }
    }
}
