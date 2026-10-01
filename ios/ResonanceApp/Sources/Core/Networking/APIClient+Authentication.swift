import Foundation

extension APIClient {
  /// Exchanges a one-time authorization code for the complete local session identity.
  func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> AuthSession {
    let url = ServiceConfiguration.apiBaseURL.appendingPathComponent("auth/session")
    let body = [
      "code": code,
      "redirectUri": ServiceConfiguration.authCallbackURL.absoluteString,
      "codeVerifier": codeVerifier,
    ]
    let response: TokenResponse = try await send(
      url: url, method: "POST", body: body, accessToken: nil)
    guard let user = response.user else { throw URLError(.badServerResponse) }
    return AuthSession(
      accessToken: response.accessToken, refreshToken: response.refreshToken, userId: user.id,
      displayName: user.displayName, globalRole: user.globalRole)
  }

  func refreshTokens(refreshToken: String) async throws -> (
    accessToken: String, refreshToken: String
  ) {
    let url = ServiceConfiguration.apiBaseURL.appendingPathComponent("auth/refresh")
    let response: TokenResponse = try await send(
      url: url, method: "POST", body: ["refreshToken": refreshToken], accessToken: nil)
    return (response.accessToken, response.refreshToken)
  }

  func logout(accessToken: String) async throws {
    struct Response: Decodable { let success: Bool }
    let url = ServiceConfiguration.apiBaseURL.appendingPathComponent("auth/logout")
    let _: Response = try await send(
      url: url, method: "POST", body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

  func revokeRefreshToken(_ refreshToken: String) async throws {
    struct Body: Encodable { let refreshToken: String }
    struct Response: Decodable { let success: Bool }
    let url = ServiceConfiguration.apiBaseURL.appendingPathComponent("auth/logout")
    let _: Response = try await send(
      url: url, method: "POST", body: Body(refreshToken: refreshToken), accessToken: nil)
  }
}
