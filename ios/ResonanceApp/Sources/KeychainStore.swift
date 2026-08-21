import Foundation
import os
import Security

// Encapsulates device-bound keychain reads, writes, and error translation for sensitive local state.

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "KeychainStore")

/// Verified persistence operations for the local-data owner marker.
struct LocalDataOwnerStore {
    let read: () throws -> String?
    let write: (String) throws -> Void
    let remove: () throws -> Void
}

/// Stores credentials so persisted authentication and calendar data never fall back to plaintext storage.
enum KeychainStore {
    /// Security's CFString constants are not Sendable. Create the bridge at
    /// the call site instead of retaining shared mutable Core Foundation state.
    static var itemAccessibility: CFString {
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    static func accountKey(for key: String) -> String {
        "\(AppConfig.keychainNamespace).\(key)"
    }

    static func localDataOwnerStore() -> LocalDataOwnerStore {
        LocalDataOwnerStore(
            read: { try KeychainStore.read("localDataOwnerId") },
            write: { try KeychainStore.store($0, for: "localDataOwnerId") },
            remove: { try KeychainStore.removeStoredValue(for: "localDataOwnerId") }
        )
    }

    static func store(_ value: String, for key: String) throws {
        try store(Data(value.utf8), for: key)
        guard try read(key) == value else {
            throw KeychainStoreError.valueVerificationFailed(key)
        }
    }

    static func store(_ data: Data, for key: String) throws {
        let accountKey = accountKey(for: key)
        let query = itemQuery(accountKey: accountKey)
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
        let query = itemQuery(accountKey: accountKey).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }
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
        let query = itemQuery(accountKey: accountKey(for: key))
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed("remove", key: key, status: status)
        }
        guard try read(key) == nil else {
            throw KeychainStoreError.removalVerificationFailed(key)
        }
    }

    private static func itemQuery(accountKey: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: accountKey]
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
