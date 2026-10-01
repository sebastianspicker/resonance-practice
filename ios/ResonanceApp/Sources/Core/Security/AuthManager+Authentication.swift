import AuthenticationServices
import UIKit

// Implements authorization-browser flow, callback validation, and local session loading.

extension AuthManager {
  /// Loads only a fully verified persisted session, failing closed when credential state is uncertain.
  func loadSession() {
    do {
      if try isSessionPersistenceUncertain() {
        recoverUncertainSessionPersistence()
        return
      }
      guard let data = try readSessionData() else {
        discardLegacySessionCredentials()
        session = nil
        return
      }
      session = try JSONDecoder().decode(AuthSession.self, from: data)
      discardLegacySessionCredentials()
    } catch {
      Self.logger.error("Failed to load the stored auth session: \(error.localizedDescription)")
      session = nil
      authError = "Sign-in blocked: local credential state could not be verified."
    }
  }

  func signIn() {
    authSession?.cancel()
    pendingCodeVerifier = nil
    let attemptID = UUID()
    authAttemptID = attemptID
    authError = nil
    isAuthenticating = true
    let verifier: String
    do {
      verifier = try PKCE.makeVerifier()
    } catch {
      handleFailedAuthenticationSessionStart(error: error)
      return
    }
    pendingCodeVerifier = verifier
    let session = ASWebAuthenticationSession(
      url: ServiceConfiguration.authLoginURL(codeChallenge: PKCE.s256Challenge(for: verifier)),
      callbackURLScheme: ServiceConfiguration.authCallbackScheme
    ) { [weak self] callbackURL, error in
      self?.handleAuthenticationCallback(callbackURL, error: error, attemptID: attemptID)
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = true
    authSession = session
    guard session.start() else {
      handleFailedAuthenticationSessionStart()
      return
    }
  }

  func handleAuthenticationCallback(_ callbackURL: URL?, error: Error?, attemptID: UUID) {
    guard authAttemptID == attemptID else { return }
    if let error {
      handleAuthenticationSessionError(error)
      return
    }
    guard let callbackURL else {
      handleMissingAuthenticationCallback()
      return
    }
    guard ServiceConfiguration.isExpectedAuthCallback(callbackURL) else {
      handleUnexpectedAuthenticationCallback()
      return
    }
    guard let code = authorizationCode(from: callbackURL) else {
      handleMissingAuthorizationCode(in: callbackURL)
      return
    }
    guard let verifier = pendingCodeVerifier else {
      handleMissingCodeVerifier()
      return
    }
    exchangeAuthorizationCode(code, codeVerifier: verifier, for: attemptID)
  }

  func handleAuthenticationSessionError(_ error: Error) {
    authAttemptID = nil
    pendingCodeVerifier = nil
    isAuthenticating = false
    Self.logger.error("Authentication session error: \(error.localizedDescription)")
    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
      authError = "Sign-in failed: \(error.localizedDescription)"
    }
  }

  func handleMissingAuthenticationCallback() {
    authAttemptID = nil
    pendingCodeVerifier = nil
    isAuthenticating = false
    Self.logger.error("Auth callback returned no URL and no error")
    authError = "Sign-in failed: no response received"
  }

  func handleMissingAuthorizationCode(in callbackURL: URL) {
    authAttemptID = nil
    pendingCodeVerifier = nil
    isAuthenticating = false
    Self.logger.warning(
      "Auth callback URL missing 'code' parameter: \(callbackURL.absoluteString, privacy: .private)"
    )
    authError = "Sign-in failed: authorization code missing from callback"
  }

  func handleUnexpectedAuthenticationCallback() {
    authAttemptID = nil
    pendingCodeVerifier = nil
    isAuthenticating = false
    Self.logger.warning("Rejected authentication callback that did not match the configured route")
    authError = "Sign-in failed: invalid callback"
  }

  func handleMissingCodeVerifier() {
    authAttemptID = nil
    pendingCodeVerifier = nil
    isAuthenticating = false
    Self.logger.error("Sign-in callback arrived without a pending PKCE verifier")
    authError = "Sign-in failed: secure sign-in state was lost"
  }

  func authorizationCode(from callbackURL: URL) -> String? {
    URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems?.first {
      $0.name == "code"
    }?.value
  }

  func exchangeAuthorizationCode(_ code: String, codeVerifier: String, for attemptID: UUID) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let newSession = try await self.apiClient.exchangeCodeForTokens(
          code: code,
          codeVerifier: codeVerifier
        )
        guard self.authAttemptID == attemptID else { return }
        try self.persistSession(newSession)
        guard self.authAttemptID == attemptID else { return }
        self.authAttemptID = nil
        self.pendingCodeVerifier = nil
        self.isAuthenticating = false
      } catch {
        guard self.authAttemptID == attemptID else { return }
        self.authAttemptID = nil
        self.pendingCodeVerifier = nil
        self.isAuthenticating = false
        Self.logger.error("Auth code exchange or persistence failed: \(error.localizedDescription)")
        self.authError = "Sign-in failed: local credentials could not be saved"
      }
    }
  }

  func handleFailedAuthenticationSessionStart(error: Error? = nil) {
    authAttemptID = nil
    pendingCodeVerifier = nil
    authSession = nil
    isAuthenticating = false
    if let error {
      Self.logger.error("Failed to prepare secure sign-in state: \(error.localizedDescription)")
      authError = "Sign-in failed: unable to prepare secure sign-in"
    } else {
      Self.logger.error("Failed to start ASWebAuthenticationSession")
      authError = "Sign-in failed: unable to open login page"
    }
  }

  /// Revokes local and remote credentials while preserving the session when secure deletion fails.
  func signOut() {
    let currentSession: AuthSession?
    do { currentSession = try clearLocalSessionReturningPreviousSession() } catch {
      Self.logger.error(
        "Failed to remove local credentials during sign-out: \(error.localizedDescription)")
      authError = "Sign-out failed: local credentials could not be removed."
      return
    }
    revokeRemoteSession(currentSession)
  }

  func revokeRemoteSession(_ currentSession: AuthSession?) {
    Task { @MainActor [weak self] in
      guard let self, let currentSession else { return }
      do { try await self.apiClient.logout(accessToken: currentSession.accessToken) } catch {
        Self.logger.warning(
          "Server logout failed, attempting refresh-token revocation: \(error.localizedDescription)"
        )
        do { try await self.apiClient.revokeRefreshToken(currentSession.refreshToken) } catch {
          Self.logger.warning(
            "Refresh-token revocation also failed (local credentials still cleared): \(error.localizedDescription)"
          )
        }
      }
    }
  }
}

extension AuthManager: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
      .first { $0.isKeyWindow } ?? ASPresentationAnchor()
  }
}
