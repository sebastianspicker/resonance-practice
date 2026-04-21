import Foundation
import AuthenticationServices
import os

struct AuthSession: Codable {
    var accessToken: String
    var refreshToken: String
    var userId: String
    var displayName: String
    var globalRole: String
}

@MainActor
final class AuthManager: NSObject, ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "AuthManager")

    @Published var session: AuthSession?
    /// User-visible error message from the most recent sign-in attempt.
    /// Set on callback failure so the UI can display feedback instead of
    /// silently doing nothing (bug #39).
    @Published var authError: String?
    private var authSession: ASWebAuthenticationSession?
    private let apiClient: APIClient
    private var refreshTask: Task<Void, Error>?

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
        super.init()
        loadSession()
    }

    func loadSession() {
        guard let access = KeychainStore.get("accessToken"),
              let refresh = KeychainStore.get("refreshToken"),
              let userId = KeychainStore.get("userId"),
              let displayName = KeychainStore.get("displayName"),
              let role = KeychainStore.get("globalRole") else {
            session = nil
            return
        }
        session = AuthSession(accessToken: access, refreshToken: refresh, userId: userId, displayName: displayName, globalRole: role)
    }

    func signIn() {
        let callbackScheme = AppConfig.authCallbackScheme
        let authURL = AppConfig.devLoginURL

        authError = nil
        authSession = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
            guard let self else { return }
            if let error {
                Self.logger.error("Authentication session error: \(error.localizedDescription)")
                // Don't set authError for user-cancelled (ASWebAuthenticationSessionError.canceledLogin)
                if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                    self.authError = "Sign-in failed: \(error.localizedDescription)"
                }
                return
            }
            guard let callbackURL else {
                Self.logger.error("Auth callback returned no URL and no error")
                self.authError = "Sign-in failed: no response received"
                return
            }
            guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                Self.logger.warning("Auth callback URL missing 'code' parameter: \(callbackURL.absoluteString, privacy: .private)")
                self.authError = "Sign-in failed: authorization code missing from callback"
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let session = try await self.apiClient.exchangeCodeForTokens(code: code)
                    self.persistSession(session)
                } catch {
                    Self.logger.error("Auth code exchange failed: \(error.localizedDescription)")
                    self.authError = "Sign-in failed: could not exchange authorization code"
                }
            }
        }
        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = true
        let started = authSession?.start() ?? false
        if !started {
            Self.logger.error("Failed to start ASWebAuthenticationSession")
            authError = "Sign-in failed: unable to open login page"
        }
    }

    func signInForScreenshot(role: ScreenshotPersona) async throws {
        let userId: String
        switch role {
        case .student:
            userId = AppConfig.screenshotStudentUserId
        case .teacher:
            userId = AppConfig.screenshotTeacherUserId
        }
        let code = try await apiClient.issueDevCode(role: role.rawValue, userId: userId)
        let session = try await apiClient.exchangeCodeForTokens(code: code)
        persistSession(session)
    }

    func signOut() {
        // Capture the current session before clearing, then attempt server-side
        // logout inside the background Task. Credentials are cleared after the
        // API call completes (or fails) to avoid revoking tokens the server
        // never sees.
        let currentSession = session
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let currentSession {
                do {
                    try await self.apiClient.logout(accessToken: currentSession.accessToken)
                } catch {
                    // Access-token logout failed (likely expired). Try refresh-token revocation.
                    Self.logger.warning("Server logout failed, attempting refresh-token revocation: \(error.localizedDescription)")
                    do {
                        try await self.apiClient.revokeRefreshToken(currentSession.refreshToken)
                    } catch {
                        Self.logger.warning("Refresh-token revocation also failed (local credentials still cleared): \(error.localizedDescription)")
                    }
                }
            }

            // Clear local credentials after the server call
            KeychainStore.remove("accessToken")
            KeychainStore.remove("refreshToken")
            KeychainStore.remove("userId")
            KeychainStore.remove("displayName")
            KeychainStore.remove("globalRole")
            self.session = nil
        }
    }

    func refreshIfNeeded() async {
        guard let session else { return }

        // If a refresh is already in progress, coalesce by awaiting the existing task.
        if let existingTask = refreshTask {
            do {
                try await existingTask.value
            } catch {
                Self.logger.error("Coalesced token refresh failed, signing out: \(error.localizedDescription)")
                signOut()
            }
            return
        }

        // Only refresh if the access token is expired or within 60 seconds of expiry.
        guard isAccessTokenExpired(session.accessToken) else { return }

        // Assign refreshTask *before* awaiting so concurrent callers
        // always see the in-flight task and coalesce onto it.
        refreshTask = Task {
            defer { refreshTask = nil }
            let refreshed = try await apiClient.refreshTokens(refreshToken: session.refreshToken)
            let newSession = AuthSession(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                userId: session.userId,
                displayName: session.displayName,
                globalRole: session.globalRole
            )
            persistSession(newSession)
        }

        do {
            try await refreshTask!.value
        } catch {
            Self.logger.error("Token refresh failed, signing out: \(error.localizedDescription)")
            authError = "Session expired. Sign in again."
            signOut()
        }
    }

    /// Returns true if the JWT access token is expired or will expire within 60 seconds.
    private func isAccessTokenExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return true }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return true
        }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 60
    }

    private func persistSession(_ session: AuthSession) {
        KeychainStore.set(session.accessToken, for: "accessToken")
        KeychainStore.set(session.refreshToken, for: "refreshToken")
        KeychainStore.set(session.userId, for: "userId")
        KeychainStore.set(session.displayName, for: "displayName")
        KeychainStore.set(session.globalRole, for: "globalRole")
        self.session = session
        self.authError = nil
    }
}

extension AuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
