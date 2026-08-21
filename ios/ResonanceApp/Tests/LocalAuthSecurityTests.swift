import Foundation
import Security
import XCTest

@testable import ResonanceApp

final class LocalAuthSecurityTests: XCTestCase {
  func testRefreshTokensUseDeviceOnlyKeychainAccessibility() {
    XCTAssertEqual(
      KeychainStore.itemAccessibility as String,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
  }

  @MainActor
  func testSignOutKeepsSessionWhenCredentialRemovalFails() {
    let manager = AuthManager(
      apiClient: APIClient(),
      removeSessionData: {
        throw KeychainStoreError.operationFailed(
          "remove", key: "authSession", status: errSecAuthFailed)
      })
    manager.session = makeSession()

    manager.signOut()

    XCTAssertEqual(manager.session?.userId, "student-1")
    XCTAssertEqual(manager.authError, "Sign-out failed: local credentials could not be removed.")
  }

  @MainActor
  func testPersistenceRollbackFailureKeepsSafetyMarkerAndBlocksReload() {
    let harness = SessionPersistenceHarness()
    harness.persistBeforeStoreFailure = true
    harness.storeFailure = KeychainStoreError.valueVerificationFailed("authSession")
    harness.removeFailure = KeychainStoreError.removalVerificationFailed("authSession")
    let manager = harness.makeManager()

    XCTAssertThrowsError(try manager.persistSession(makeSession())) { error in
      XCTAssertEqual(error as? AuthSessionPersistenceError, .rollbackFailed)
    }
    XCTAssertNil(manager.session)
    XCTAssertNotNil(harness.persistedData)
    XCTAssertTrue(harness.persistenceUncertain)
    XCTAssertNil(harness.makeManager().session)
  }

  @MainActor
  func testSuccessfulPersistenceAndRefreshReplaceDurableSession() async throws {
    let harness = SessionPersistenceHarness()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeferredAuthURLProtocol.self]
    let manager = harness.makeManager(
      apiClient: APIClient(session: URLSession(configuration: configuration)))
    let initial = makeSession(accessToken: makeAuthJWT(expiresIn: -60))
    try manager.persistSession(initial)
    XCTAssertEqual(harness.makeManager().session?.refreshToken, initial.refreshToken)

    DeferredAuthURLProtocol.requestHandler = { protocolInstance, request in
      XCTAssertEqual(request.url?.path, "/auth/refresh")
      protocolInstance.respond(statusCode: 200, data: self.refreshedTokenResponse())
    }
    defer { DeferredAuthURLProtocol.requestHandler = nil }
    await manager.refreshIfNeeded()

    XCTAssertEqual(manager.session?.refreshToken, "replacement-token")
    XCTAssertEqual(harness.makeManager().session?.refreshToken, "replacement-token")
  }

  @MainActor
  func testCancelledRefreshCannotReplaceNewerSession() async throws {
    let refreshStarted = expectation(description: "refresh started")
    let logoutCompleted = expectation(description: "logout completed")
    let harness = DeferredRefreshHarness(
      refreshStarted: refreshStarted, logoutCompleted: logoutCompleted)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeferredAuthURLProtocol.self]
    let manager = AuthManager(
      apiClient: APIClient(session: URLSession(configuration: configuration)), removeSessionData: {}
    )
    manager.session = makeSession(accessToken: makeAuthJWT(expiresIn: -60))
    DeferredAuthURLProtocol.requestHandler = { protocolInstance, request in
      switch request.url?.path {
      case "/auth/refresh":
        harness.deferredRefresh = protocolInstance
        harness.refreshStarted.fulfill()
      case "/auth/logout":
        protocolInstance.respond(statusCode: 200, data: Data("{\"success\":true}".utf8))
        harness.logoutCompleted.fulfill()
      default:
        XCTFail("Unexpected request path")
      }
    }
    defer { DeferredAuthURLProtocol.requestHandler = nil }

    let refreshTask = Task { await manager.refreshIfNeeded() }
    await fulfillment(of: [refreshStarted], timeout: 1)
    manager.signOut()
    await fulfillment(of: [logoutCompleted], timeout: 1)
    let replacement = makeSession(refreshToken: "new-sign-in-refresh-token", userId: "student-2")
    manager.session = replacement
    try XCTUnwrap(harness.deferredRefresh).respond(statusCode: 200, data: refreshedTokenResponse())
    await refreshTask.value

    XCTAssertEqual(manager.session?.refreshToken, replacement.refreshToken)
    XCTAssertEqual(manager.session?.userId, replacement.userId)
  }

  private func makeSession(
    accessToken: String = makeAuthJWT(expiresIn: 3_600), refreshToken: String = "refresh-token",
    userId: String = "student-1"
  ) -> AuthSession {
    AuthSession(
      accessToken: accessToken, refreshToken: refreshToken, userId: userId, displayName: "Student",
      globalRole: "student")
  }

  private func refreshedTokenResponse() -> Data {
    Data(
      "{\"accessToken\":\"\(makeAuthJWT(expiresIn: 3_600))\",\"refreshToken\":\"replacement-token\"}"
        .utf8)
  }
}

private final class SessionPersistenceHarness {
  var persistedData: Data?
  var persistenceUncertain = false
  var persistBeforeStoreFailure = false
  var storeFailure: Error?
  var removeFailure: Error?

  @MainActor
  func makeManager(apiClient: APIClient = APIClient()) -> AuthManager {
    AuthManager(
      apiClient: apiClient,
      storeSessionData: { data in
        if self.persistBeforeStoreFailure { self.persistedData = data }
        if let storeFailure = self.storeFailure { throw storeFailure }
        self.persistedData = data
      },
      readSessionData: { self.persistedData },
      removeSessionData: {
        if let removeFailure = self.removeFailure { throw removeFailure }
        self.persistedData = nil
      },
      setSessionPersistenceUncertain: { self.persistenceUncertain = $0 },
      isSessionPersistenceUncertain: { self.persistenceUncertain }
    )
  }
}

private final class DeferredRefreshHarness {
  let refreshStarted: XCTestExpectation
  let logoutCompleted: XCTestExpectation
  var deferredRefresh: DeferredAuthURLProtocol?

  init(refreshStarted: XCTestExpectation, logoutCompleted: XCTestExpectation) {
    self.refreshStarted = refreshStarted
    self.logoutCompleted = logoutCompleted
  }
}

private final class DeferredAuthURLProtocol: TestURLProtocolBase {
  nonisolated(unsafe) static var requestHandler: ((DeferredAuthURLProtocol, URLRequest) -> Void)?

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("DeferredAuthURLProtocol.requestHandler not set")
      return
    }
    handler(self, request)
  }

  override func stopLoading() {}

  func respond(statusCode: Int, data: Data) {
    guard let url = request.url else {
      XCTFail("Deferred request URL is missing")
      return
    }
    let response = HTTPURLResponse(
      url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
}

private func makeAuthJWT(expiresIn: TimeInterval) -> String {
  let header = base64URLString(from: Data("{\"alg\":\"none\"}".utf8))
  let expiration = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
  let payload = base64URLString(from: Data("{\"exp\":\(expiration)}".utf8))
  return "\(header).\(payload).signature"
}
