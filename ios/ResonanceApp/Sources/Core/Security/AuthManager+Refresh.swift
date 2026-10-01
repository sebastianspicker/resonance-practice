import Foundation

// Coordinates a single shared refresh task so concurrent callers cannot rotate tokens independently.

extension AuthManager {
  /// Reuses any in-flight refresh and accepts its result only for the originating refresh token.
  func refreshIfNeeded() async {
    guard let session else { return }
    if let existingTask = refreshTask {
      await awaitRefreshTask(existingTask, refreshToken: session.refreshToken)
      return
    }
    guard isAccessTokenExpired(session.accessToken) else { return }
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
      try self.persistSession(
        AuthSession(
          accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken,
          userId: session.userId, displayName: session.displayName, globalRole: session.globalRole))
    }
    refreshTask = task
    do { try await task.value } catch {
      guard self.session?.refreshToken == refreshToken else { return }
      Self.logger.error("Token refresh failed, signing out: \(error.localizedDescription)")
      authError = "Session expired. Sign in again."
      signOut()
    }
  }

  func awaitRefreshTask(_ task: Task<Void, Error>, refreshToken: String) async {
    do { try await task.value } catch {
      guard session?.refreshToken == refreshToken else { return }
      Self.logger.error(
        "Coalesced token refresh failed, signing out: \(error.localizedDescription)")
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
