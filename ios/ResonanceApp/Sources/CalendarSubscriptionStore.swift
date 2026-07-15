import Foundation
import os

private let calendarSubscriptionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "resonance",
    category: "CalendarSubscriptionStore"
)

enum CalendarSubscriptionStore {
    private static let keychainKey = "calendarSubscriptionURL"
    private static let legacyDefaultsKey = "icalURL"

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

    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try KeychainStore.removeStoredValue(for: keychainKey)
        } else {
            try KeychainStore.store(trimmed, for: keychainKey)
        }
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

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
