import Foundation

// Coordinates a single shared refresh task so concurrent callers cannot rotate tokens independently.

/// A refreshed session that could not be stored locally; the old refresh token is already rotated.
private struct RefreshedSessionPersistenceError: Error {
  let underlying: Error
}

extension AuthManager {
  /// Server codes that mean the refresh token itself is no longer valid.
  static let refreshRejectionCodes: Set<String> = [
    "INVALID_REFRESH",
    "REFRESH_REVOKED",
    "REFRESH_MISMATCH",
    "REFRESH_ALREADY_USED",
    "USER_NOT_FOUND"
  ]

  /// True only for failures after which the session cannot recover by retrying later.
  /// Network errors, timeouts, rate limits and server errors keep the session.
  static func refreshFailureEndsSession(_ error: Error) -> Bool {
    if error is RefreshedSessionPersistenceError { return true }
    guard let apiError = error as? APIError else { return false }
    return refreshRejectionCodes.contains(apiError.error.code)
  }

  /// Reuses any in-flight refresh and accepts its result only for the originating refresh token.
  /// `force` refreshes even when the local expiry check passes, e.g. after the server rejected
  /// the access token.
  func refreshIfNeeded(force: Bool = false) async {
    guard let session else { return }
    if let existingTask = refreshTask {
      await awaitRefreshTask(existingTask, refreshToken: session.refreshToken)
      return
    }
    guard force || isAccessTokenExpired(session.accessToken) else { return }
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
      guard !Task.isCancelled, self.session?.refreshToken == refreshToken else { return }
      do {
        try self.persistSession(
          AuthSession(
            accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken,
            userId: session.userId, displayName: session.displayName,
            globalRole: session.globalRole))
      } catch {
        throw RefreshedSessionPersistenceError(underlying: error)
      }
    }
    refreshTask = task
    await awaitRefreshTask(task, refreshToken: refreshToken)
  }

  func awaitRefreshTask(_ task: Task<Void, Error>, refreshToken: String) async {
    do { try await task.value } catch {
      guard session?.refreshToken == refreshToken else { return }
      guard Self.refreshFailureEndsSession(error) else {
        Self.logger.warning(
          "Token refresh failed; keeping session for retry: \(error.localizedDescription)")
        return
      }
      Self.logger.error("Token refresh rejected, signing out: \(error.localizedDescription)")
      authError = "Session expired. Sign in again."
      signOut()
    }
  }

  func isAccessTokenExpired(_ token: String) -> Bool {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return true }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    guard let data = Data(base64Encoded: base64),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let exp = json["exp"] as? TimeInterval
    else { return true }
    return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 60
  }
}
