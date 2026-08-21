import Foundation

/// Codable credential set whose refresh token identifies the durable local session.
struct AuthSession: Codable {
    var accessToken: String
    var refreshToken: String
    var userId: String
    var displayName: String
    var globalRole: String
}

/// Signals that credential persistence cannot be proven safe and must fail closed.
enum AuthSessionPersistenceError: LocalizedError, Equatable {
    case rollbackFailed
    case uncertaintySentinelVerificationFailed

    var errorDescription: String? {
        switch self {
        case .rollbackFailed:
            return "The failed credential write could not be rolled back safely."
        case .uncertaintySentinelVerificationFailed:
            return "The local credential safety sentinel could not be verified."
        }
    }
}

// Owns the independent sentinel that prevents ambiguous credential writes from being trusted.
enum AuthSessionPersistenceSupport {
    static func setDefaultSessionPersistenceUncertain(_ uncertain: Bool) throws {
        let sentinelURL = try sentinelURL()
        if uncertain {
            try Data([1]).write(to: sentinelURL, options: .atomic)
            guard FileManager.default.fileExists(atPath: sentinelURL.path) else {
                throw AuthSessionPersistenceError.uncertaintySentinelVerificationFailed
            }
            try KeychainStore.store("1", for: "authSessionPersistenceUncertain")
            return
        }

        // Keep the independent filesystem sentinel until Keychain marker removal
        // has completed and verified. If Keychain deletion becomes ambiguous, the
        // remaining file forces the next launch down the recovery path.
        try KeychainStore.removeStoredValue(for: "authSessionPersistenceUncertain")
        if FileManager.default.fileExists(atPath: sentinelURL.path) {
            try FileManager.default.removeItem(at: sentinelURL)
        }
        guard !FileManager.default.fileExists(atPath: sentinelURL.path) else {
            throw AuthSessionPersistenceError.uncertaintySentinelVerificationFailed
        }
    }

    static func isDefaultSessionPersistenceUncertain() throws -> Bool {
        let sentinelURL = try sentinelURL()
        if FileManager.default.fileExists(atPath: sentinelURL.path) {
            return true
        }
        return try KeychainStore.read("authSessionPersistenceUncertain") != nil
    }

    private static func sentinelURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appendingPathComponent(
            "\(AppConfig.keychainNamespace)-auth-session-persistence-uncertain"
        )
    }
}
