import Foundation
import os

// Persists the optional iCalendar subscription URL in the keychain with legacy migration.

private let calendarSubscriptionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "resonance",
    category: "CalendarSubscriptionStore"
)

/// Keeps the subscription in Keychain and removes the legacy defaults copy after migration.
enum CalendarSubscriptionStore {
    private static let keychainKey = "calendarSubscriptionURL"
    private static let legacyDefaultsKey = "icalURL"

    /// Loads the secure value, migrating a legacy preference when possible.
    static func load() -> String {
        do {
            if let stored = try KeychainStore.read(keychainKey) {
                return stored
            }

            if let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey), legacy.isEmpty == false {
                try KeychainStore.store(legacy, for: keychainKey)
                UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
                return legacy
            }
        } catch {
            calendarSubscriptionLogger.error("Failed to load the calendar subscription: \(error.localizedDescription)")
        }

        return UserDefaults.standard.string(forKey: legacyDefaultsKey) ?? ""
    }

    /// Stores a trimmed URL or treats an empty value as an explicit removal.
    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try KeychainStore.removeStoredValue(for: keychainKey)
        } else {
            try KeychainStore.store(trimmed, for: keychainKey)
        }
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    /// Removes and verifies both secure and legacy copies before reporting success.
    static func removeStoredURL() throws {
        try KeychainStore.removeStoredValue(for: keychainKey)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        guard try KeychainStore.read(keychainKey) == nil,
              UserDefaults.standard.string(forKey: legacyDefaultsKey) == nil else {
            throw CalendarSubscriptionStoreError.removalVerificationFailed
        }
    }
}

enum CalendarSubscriptionStoreError: LocalizedError {
    case removalVerificationFailed

    var errorDescription: String? {
        "The calendar subscription could not be removed."
    }
}
