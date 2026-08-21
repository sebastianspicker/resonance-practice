import Foundation
import os

// Implements fail-closed keychain persistence and recovery for authenticated sessions.

extension AuthManager {
  static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "AuthManager")
  static let legacySessionKeys = [
    "accessToken", "refreshToken", "userId", "displayName", "globalRole"
  ]

  static func clearPersistedSessionForLocalReset() throws {
    try removeDefaultSessionData()
    try AuthSessionPersistenceSupport.setDefaultSessionPersistenceUncertain(false)
    guard try KeychainStore.readData("authSession") == nil,
      try !AuthSessionPersistenceSupport.isDefaultSessionPersistenceUncertain()
    else {
      throw AuthSessionPersistenceError.uncertaintySentinelVerificationFailed
    }
  }

  /// Commits session credentials atomically enough to detect and recover a partial keychain write.
  func persistSession(_ session: AuthSession) throws {
    try clearUncertainSessionPersistence()
    let data = try JSONEncoder().encode(session)
    try setSessionPersistenceUncertain(true)
    do {
      try storeSessionData(data)
      try setSessionPersistenceUncertain(false)
    } catch {
      let persistenceError = error
      do {
        try removeSessionData()
        try setSessionPersistenceUncertain(false)
      } catch {
        Self.logger.fault("Failed auth persistence rollback: \(error.localizedDescription)")
        self.session = nil
        self.authError = "Sign-in blocked: local credential state could not be verified."
        throw AuthSessionPersistenceError.rollbackFailed
      }
      throw persistenceError
    }
    discardLegacySessionCredentials()
    self.session = session
    authError = nil
  }

  func recoverUncertainSessionPersistence() {
    session = nil
    do { try clearUncertainSessionPersistence() } catch {
      Self.logger.fault(
        "Failed to recover uncertain auth persistence: \(error.localizedDescription)")
      authError = "Sign-in blocked: local credential state could not be verified."
    }
  }

  func clearUncertainSessionPersistence() throws {
    guard try isSessionPersistenceUncertain() else { return }
    try removeSessionData()
    try setSessionPersistenceUncertain(false)
  }

  func clearLocalSession() throws {
    _ = try clearLocalSessionReturningPreviousSession()
  }

  func clearLocalSessionReturningPreviousSession() throws -> AuthSession? {
    let currentSession = session
    authAttemptID = nil
    authSession?.cancel()
    authSession = nil
    refreshTask?.cancel()
    refreshTask = nil
    refreshTaskID = nil
    try removeSessionData()
    session = nil
    return currentSession
  }

  static func removeDefaultSessionData() throws {
    try KeychainStore.removeStoredValue(for: "authSession")
    for key in legacySessionKeys { try KeychainStore.removeStoredValue(for: key) }
  }

  func discardLegacySessionCredentials() {
    for key in Self.legacySessionKeys {
      do { try KeychainStore.removeStoredValue(for: key) } catch {
        Self.logger.warning(
          "Failed to remove legacy auth credential: \(error.localizedDescription)")
      }
    }
  }
}
