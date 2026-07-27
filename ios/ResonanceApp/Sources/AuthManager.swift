import AuthenticationServices
import Foundation
import os

// Owns authenticated identity, secure credential dependencies, and browser-session state.

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
    case .rollbackFailed: return "The failed credential write could not be rolled back safely."
    case .uncertaintySentinelVerificationFailed:
      return "The local credential safety sentinel could not be verified."
    }
  }
}

private func authSessionPersistenceSentinelURL() throws -> URL {
  let directory = try FileManager.default.url(
    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
  return directory.appendingPathComponent(
    "\(AppConfig.keychainNamespace)-auth-session-persistence-uncertain")
}

private func setDefaultSessionPersistenceUncertain(_ uncertain: Bool) throws {
  let sentinelURL = try authSessionPersistenceSentinelURL()
  if uncertain {
    try Data([1]).write(to: sentinelURL, options: .atomic)
    guard FileManager.default.fileExists(atPath: sentinelURL.path) else {
      throw AuthSessionPersistenceError.uncertaintySentinelVerificationFailed
    }
    try KeychainStore.store("1", for: "authSessionPersistenceUncertain")
    return
  }
  try KeychainStore.removeStoredValue(for: "authSessionPersistenceUncertain")
  if FileManager.default.fileExists(atPath: sentinelURL.path) {
    try FileManager.default.removeItem(at: sentinelURL)
  }
  guard !FileManager.default.fileExists(atPath: sentinelURL.path) else {
    throw AuthSessionPersistenceError.uncertaintySentinelVerificationFailed
  }
}

private func isDefaultSessionPersistenceUncertain() throws -> Bool {
  let sentinelURL = try authSessionPersistenceSentinelURL()
  if FileManager.default.fileExists(atPath: sentinelURL.path) { return true }
  return try KeychainStore.read("authSessionPersistenceUncertain") != nil
}

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

private func authSessionPersistenceSentinelURL() throws -> URL {
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

private func setDefaultSessionPersistenceUncertain(_ uncertain: Bool) throws {
    let sentinelURL = try authSessionPersistenceSentinelURL()
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

private func isDefaultSessionPersistenceUncertain() throws -> Bool {
    let sentinelURL = try authSessionPersistenceSentinelURL()
    if FileManager.default.fileExists(atPath: sentinelURL.path) {
        return true
    }
    return try KeychainStore.read("authSessionPersistenceUncertain") != nil
}

@MainActor
/// Coordinates sign-in state while keeping persistence operations injectable for secure failure handling.
final class AuthManager: NSObject, ObservableObject {
  static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "AuthManager")
  static let legacySessionKeys = [
    "accessToken", "refreshToken", "userId", "displayName", "globalRole"
  ]

  @Published var session: AuthSession?
  @Published var authError: String?
  /// True while ASWebAuthenticationSession / token exchange is in flight.
  @Published var isAuthenticating = false
  var authSession: ASWebAuthenticationSession?
  var authAttemptID: UUID?
  let apiClient: APIClient
  let storeSessionData: (Data) throws -> Void
  let readSessionData: () throws -> Data?
  let removeSessionData: () throws -> Void
  let setSessionPersistenceUncertain: (Bool) throws -> Void
  let isSessionPersistenceUncertain: () throws -> Bool
  var refreshTask: Task<Void, Error>?
  var refreshTaskID: UUID?

  init(
    apiClient: APIClient = APIClient(),
    storeSessionData: @escaping (Data) throws -> Void = {
      try KeychainStore.store($0, for: "authSession")
    },
    readSessionData: @escaping () throws -> Data? = { try KeychainStore.readData("authSession") },
    removeSessionData: @escaping () throws -> Void = { try AuthManager.removeDefaultSessionData() },
    setSessionPersistenceUncertain: @escaping (Bool) throws -> Void = {
      try setDefaultSessionPersistenceUncertain($0)
    },
    isSessionPersistenceUncertain: @escaping () throws -> Bool = {
      try isDefaultSessionPersistenceUncertain()
    }
  ) {
    self.apiClient = apiClient
    self.storeSessionData = storeSessionData
    self.readSessionData = readSessionData
    self.removeSessionData = removeSessionData
    self.setSessionPersistenceUncertain = setSessionPersistenceUncertain
    self.isSessionPersistenceUncertain = isSessionPersistenceUncertain
    super.init()
    loadSession()
  }

  static func clearPersistedSessionForLocalReset() throws {
    try removeDefaultSessionData()
    try setDefaultSessionPersistenceUncertain(false)
    guard try KeychainStore.readData("authSession") == nil,
      try !isDefaultSessionPersistenceUncertain()
    else {
      throw AuthSessionPersistenceError.uncertaintySentinelVerificationFailed
    }
  }
}

extension AuthManager: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
      .first { $0.isKeyWindow } ?? ASPresentationAnchor()
  }
}
