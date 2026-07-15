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
final class AuthManager: NSObject, ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "AuthManager")
    private static let legacySessionKeys = ["accessToken", "refreshToken", "userId", "displayName", "globalRole"]

    @Published var session: AuthSession?
    /// User-visible error message from the most recent sign-in attempt.
    /// Callback failures are surfaced here because ASWebAuthenticationSession
    /// can fail before the app receives a usable callback URL.
    @Published var authError: String?
    private var authSession: ASWebAuthenticationSession?
    private var authAttemptID: UUID?
    private let apiClient: APIClient
    private let storeSessionData: (Data) throws -> Void
    private let readSessionData: () throws -> Data?
    private let removeSessionData: () throws -> Void
    private let setSessionPersistenceUncertain: (Bool) throws -> Void
    private let isSessionPersistenceUncertain: () throws -> Bool
    private var refreshTask: Task<Void, Error>?
    private var refreshTaskID: UUID?

    init(
        apiClient: APIClient = APIClient(),
        storeSessionData: @escaping (Data) throws -> Void = { data in
            try KeychainStore.store(data, for: "authSession")
        },
        readSessionData: @escaping () throws -> Data? = {
            try KeychainStore.readData("authSession")
        },
        removeSessionData: @escaping () throws -> Void = {
            try KeychainStore.removeStoredValue(for: "authSession")
            for key in ["accessToken", "refreshToken", "userId", "displayName", "globalRole"] {
                try KeychainStore.removeStoredValue(for: key)
            }
        },
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
        let authAttemptID = UUID()
        self.authAttemptID = authAttemptID
        authError = nil
        let session = ASWebAuthenticationSession(
            url: AppConfig.authLoginURL,
            callbackURLScheme: AppConfig.authCallbackScheme
        ) { [weak self] callbackURL, error in
            self?.handleAuthenticationCallback(callbackURL, error: error, attemptID: authAttemptID)
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        authSession = session

        guard session.start() else {
            handleFailedAuthenticationSessionStart()
            return
        }
    }

    private func handleAuthenticationCallback(
        _ callbackURL: URL?,
        error: Error?,
        attemptID: UUID
    ) {
        guard authAttemptID == attemptID else { return }
        if let error {
            handleAuthenticationSessionError(error)
            return
        }
        guard let callbackURL else {
            handleMissingAuthenticationCallback()
            return
        }
        guard let code = authorizationCode(from: callbackURL) else {
            handleMissingAuthorizationCode(in: callbackURL)
            return
        }
        exchangeAuthorizationCode(code, for: attemptID)
    }

    private func handleAuthenticationSessionError(_ error: Error) {
        authAttemptID = nil
        Self.logger.error("Authentication session error: \(error.localizedDescription)")
        if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
            authError = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func handleMissingAuthenticationCallback() {
        authAttemptID = nil
        Self.logger.error("Auth callback returned no URL and no error")
        authError = "Sign-in failed: no response received"
    }

    private func handleMissingAuthorizationCode(in callbackURL: URL) {
        authAttemptID = nil
        Self.logger.warning("Auth callback URL missing 'code' parameter: \(callbackURL.absoluteString, privacy: .private)")
        authError = "Sign-in failed: authorization code missing from callback"
    }

    private func authorizationCode(from callbackURL: URL) -> String? {
        URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value
    }

    private func exchangeAuthorizationCode(_ code: String, for attemptID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let session: AuthSession
            do {
                session = try await self.apiClient.exchangeCodeForTokens(code: code)
            } catch {
                guard self.authAttemptID == attemptID else { return }
                self.authAttemptID = nil
                Self.logger.error("Auth code exchange failed: \(error.localizedDescription)")
                self.authError = "Sign-in failed: could not exchange authorization code"
                return
            }

            guard self.authAttemptID == attemptID else { return }

            do {
                try self.persistSession(session)
                guard self.authAttemptID == attemptID else { return }
                self.authAttemptID = nil
            } catch {
                guard self.authAttemptID == attemptID else { return }
                self.authAttemptID = nil
                Self.logger.error("Auth session persistence failed: \(error.localizedDescription)")
                self.authError = "Sign-in failed: local credentials could not be saved"
            }
        }
    }

    private func handleFailedAuthenticationSessionStart() {
        authAttemptID = nil
        authSession = nil
        Self.logger.error("Failed to start ASWebAuthenticationSession")
        authError = "Sign-in failed: unable to open login page"
    }

    func signInForScreenshot(role: ScreenshotPersona) async throws {
        let isTeacher = role == .teacher
        session = AuthSession(
            accessToken: "screenshot-only-access-token",
            refreshToken: "screenshot-only-refresh-token",
            userId: isTeacher ? AppConfig.screenshotTeacherUserId : AppConfig.screenshotStudentUserId,
            displayName: isTeacher ? "Prof. Weber" : "Lea Hoffmann",
            globalRole: "user"
        )
        authError = nil
    }

    func signOut() {
        let currentSession = session
        do {
            try clearLocalSession()
        } catch {
            Self.logger.error("Failed to remove local credentials during sign-out: \(error.localizedDescription)")
            authError = "Sign-out failed: local credentials could not be removed."
            return
        }

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
        }
    }

    func refreshIfNeeded() async {
        guard let session else { return }

        // If a refresh is already in progress, coalesce by awaiting the existing task.
        if let existingTask = refreshTask {
            await awaitRefreshTask(existingTask, refreshToken: session.refreshToken)
            return
        }

        // Only refresh if the access token is expired or within 60 seconds of expiry.
        guard isAccessTokenExpired(session.accessToken) else { return }

        // Assign refreshTask *before* awaiting so concurrent callers
        // always see the in-flight task and coalesce onto it.
        let refreshTaskID = UUID()
        let refreshToken = session.refreshToken
        self.refreshTaskID = refreshTaskID
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.refreshTaskID == refreshTaskID {
                    self.refreshTask = nil
                    self.refreshTaskID = nil
                }
            }
            let refreshed = try await self.apiClient.refreshTokens(refreshToken: refreshToken)
            guard !Task.isCancelled else { return }
            // Sign-out or another sign-in may have replaced the credentials
            // while the refresh request was in flight. Never restore a stale
            // session after that boundary has changed.
            guard self.session?.refreshToken == refreshToken else { return }
            let newSession = AuthSession(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                userId: session.userId,
                displayName: session.displayName,
                globalRole: session.globalRole
            )
            try persistSession(newSession)
        }
        refreshTask = task

        do {
            try await task.value
        } catch {
            guard self.session?.refreshToken == refreshToken else { return }
            Self.logger.error("Token refresh failed, signing out: \(error.localizedDescription)")
            authError = "Session expired. Sign in again."
            signOut()
        }
    }

    private func awaitRefreshTask(_ task: Task<Void, Error>, refreshToken: String) async {
        do {
            try await task.value
        } catch {
            guard session?.refreshToken == refreshToken else { return }
            Self.logger.error("Coalesced token refresh failed, signing out: \(error.localizedDescription)")
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
        self.authError = nil
    }

    private func recoverUncertainSessionPersistence() {
        session = nil
        do {
            try clearUncertainSessionPersistence()
        } catch {
            Self.logger.fault("Failed to recover uncertain auth persistence: \(error.localizedDescription)")
            authError = "Sign-in blocked: local credential state could not be verified."
        }
    }

    private func clearUncertainSessionPersistence() throws {
        guard try isSessionPersistenceUncertain() else { return }
        try removeSessionData()
        try setSessionPersistenceUncertain(false)
    }

    private func clearLocalSession() throws {
        authAttemptID = nil
        authSession?.cancel()
        authSession = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        try removeSessionData()
        session = nil
    }

    /// Legacy per-field credentials are never trusted. Their removal is best effort because
    /// authentication eligibility is controlled solely by the single encoded session item.
    private func discardLegacySessionCredentials() {
        for key in Self.legacySessionKeys {
            do {
                try KeychainStore.removeStoredValue(for: key)
            } catch {
                Self.logger.warning("Failed to remove legacy auth credential: \(error.localizedDescription)")
            }
        }
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
