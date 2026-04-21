import Foundation

enum CalendarSubscriptionStore {
    private static let keychainKey = "calendarSubscriptionURL"
    private static let legacyDefaultsKey = "icalURL"

    static func load() -> String {
        if let stored = KeychainStore.get(keychainKey) {
            return stored
        }

        if let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey), legacy.isEmpty == false {
            KeychainStore.set(legacy, for: keychainKey)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            return legacy
        }

        return ""
    }

    static func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.remove(keychainKey)
        } else {
            KeychainStore.set(trimmed, for: keychainKey)
        }
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }
}
