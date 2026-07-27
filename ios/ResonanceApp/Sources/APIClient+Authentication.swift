import Foundation

// Implements authentication and token-lifecycle endpoints for the shared API client.

extension APIClient {
  /// Exchanges a one-time authorization code for the complete local session identity.
  func exchangeCodeForTokens(code: String) async throws -> AuthSession {
    let url = AppConfig.apiBaseURL.appendingPathComponent("auth/session")
    let body = ["code": code, "redirectUri": AppConfig.authCallbackURL.absoluteString]
    let response: TokenResponse = try await send(
      url: url, method: "POST", body: body, accessToken: nil)
    guard let user = response.user else { throw URLError(.badServerResponse) }
    return AuthSession(
      accessToken: response.accessToken, refreshToken: response.refreshToken, userId: user.id,
      displayName: user.displayName, globalRole: user.globalRole)
  }

  func issueDevCode(role: String, userId: String? = nil) async throws -> String {
    struct Body: Encodable {
      let role: String
      let userId: String?
    }
    struct Response: Decodable { let code: String }
    let url = AppConfig.apiBaseURL.appendingPathComponent("dev/issue")
    let response: Response = try await send(
      url: url, method: "POST", body: Body(role: role, userId: userId), accessToken: nil)
    return response.code
  }

  func refreshTokens(refreshToken: String) async throws -> (
    accessToken: String, refreshToken: String
  ) {
    let url = AppConfig.apiBaseURL.appendingPathComponent("auth/refresh")
    let response: TokenResponse = try await send(
      url: url, method: "POST", body: ["refreshToken": refreshToken], accessToken: nil)
    return (response.accessToken, response.refreshToken)
  }

  func logout(accessToken: String) async throws {
    struct Response: Decodable { let success: Bool }
    let url = AppConfig.apiBaseURL.appendingPathComponent("auth/logout")
    let _: Response = try await send(
      url: url, method: "POST", body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

  func revokeRefreshToken(_ refreshToken: String) async throws {
    struct Body: Encodable { let refreshToken: String }
    struct Response: Decodable { let success: Bool }
    let url = AppConfig.apiBaseURL.appendingPathComponent("auth/logout")
    let _: Response = try await send(
      url: url, method: "POST", body: Body(refreshToken: refreshToken), accessToken: nil)
  }
}
