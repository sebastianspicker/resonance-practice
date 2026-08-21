import AuthenticationServices
import Foundation
import os

// Owns authenticated identity, secure credential dependencies, and browser-session state.

@MainActor
/// Coordinates sign-in state while keeping persistence operations injectable for secure failure handling.
final class AuthManager: NSObject, ObservableObject {
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
      try AuthSessionPersistenceSupport.setDefaultSessionPersistenceUncertain($0)
    },
    isSessionPersistenceUncertain: @escaping () throws -> Bool = {
      try AuthSessionPersistenceSupport.isDefaultSessionPersistenceUncertain()
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

}
