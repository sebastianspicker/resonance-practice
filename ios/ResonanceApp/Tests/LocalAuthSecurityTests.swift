import Foundation
import Security
import XCTest
@testable import ResonanceApp

final class LocalAuthSecurityTests: XCTestCase {
    func testRefreshTokensUseDeviceOnlyKeychainAccessibility() {
        XCTAssertEqual(
            KeychainStore.itemAccessibility as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    @MainActor
    func testSignOutClearsInMemorySessionImmediately() {
        let authManager = AuthManager(apiClient: APIClient(), removeSessionData: {})
        authManager.session = makeSession()

        authManager.signOut()

        XCTAssertNil(authManager.session)
    }

    @MainActor
    func testSignOutKeepsSessionWhenCredentialRemovalFails() {
        let authManager = AuthManager(
            apiClient: APIClient(),
            removeSessionData: {
                throw KeychainStoreError.operationFailed(
                    "remove",
                    key: "authSession",
                    status: errSecAuthFailed
                )
            }
        )
        authManager.session = makeSession()

        authManager.signOut()

        XCTAssertEqual(authManager.session?.userId, "student-1")
        XCTAssertEqual(authManager.authError, "Sign-out failed: local credentials could not be removed.")
    }

    @MainActor
    func testSessionPersistenceWriteFailureCannotPublishOrReloadPartialState() {
        var persistedData: Data?
        var persistenceUncertain = false
        var writes = 0
        let authManager = AuthManager(
            apiClient: APIClient(),
            storeSessionData: { _ in
                writes += 1
                throw KeychainStoreError.operationFailed(
                    "update",
                    key: "authSession",
                    status: errSecAuthFailed
                )
            },
            readSessionData: { persistedData },
            removeSessionData: { persistedData = nil },
            setSessionPersistenceUncertain: { persistenceUncertain = $0 },
            isSessionPersistenceUncertain: { persistenceUncertain }
        )

        XCTAssertThrowsError(try authManager.persistSession(makeSession()))
        XCTAssertEqual(writes, 1)
        XCTAssertNil(authManager.session)
        XCTAssertNil(persistedData)

        let reloadedManager = AuthManager(
            apiClient: APIClient(),
            storeSessionData: { persistedData = $0 },
            readSessionData: { persistedData },
            removeSessionData: { persistedData = nil },
            setSessionPersistenceUncertain: { persistenceUncertain = $0 },
            isSessionPersistenceUncertain: { persistenceUncertain }
        )
        XCTAssertNil(reloadedManager.session)
    }

    @MainActor
    func testPostWriteFailureRollsBackDurableSessionBeforeReload() {
        var persistedData: Data?
        var persistenceUncertain = false
        let authManager = AuthManager(
            apiClient: APIClient(),
            storeSessionData: { data in
                persistedData = data
                throw KeychainStoreError.valueVerificationFailed("authSession")
            },
            readSessionData: { persistedData },
            removeSessionData: { persistedData = nil },
            setSessionPersistenceUncertain: { persistenceUncertain = $0 },
            isSessionPersistenceUncertain: { persistenceUncertain }
        )

        XCTAssertThrowsError(try authManager.persistSession(makeSession()))
        XCTAssertNil(authManager.session)
        XCTAssertNil(persistedData)
        XCTAssertFalse(persistenceUncertain)

        let reloadedManager = AuthManager(
            apiClient: APIClient(),
            readSessionData: { persistedData },
            removeSessionData: { persistedData = nil },
            setSessionPersistenceUncertain: { persistenceUncertain = $0 },
            isSessionPersistenceUncertain: { persistenceUncertain }
        )
        XCTAssertNil(reloadedManager.session)
    }

    @MainActor
    func testRollbackFailureKeepsDurableSafetyMarkerAndBlocksReload() {
        var persistedData: Data?
        var persistenceUncertain = false
        let authManager = AuthManager(
            apiClient: APIClient(),
            storeSessionData: { data in
                persistedData = data
                throw KeychainStoreError.valueVerificationFailed("authSession")
            },
            readSessionData: { persistedData },
            removeSessionData: {
                throw KeychainStoreError.removalVerificationFailed("authSession")
            },
            setSessionPersistenceUncertain: { persistenceUncertain = $0 },
            isSessionPersistenceUncertain: { persistenceUncertain }
        )

        XCTAssertThrowsError(try authManager.persistSession(makeSession())) { error in
            XCTAssertEqual(error as? AuthSessionPersistenceError, .rollbackFailed)
        }
        XCTAssertNil(authManager.session)
        XCTAssertNotNil(persistedData)
        XCTAssertTrue(persistenceUncertain)

        let reloadedManager = AuthManager(
            apiClient: APIClient(),
            readSessionData: { persistedData },
            removeSessionData: {
                throw KeychainStoreError.removalVerificationFailed("authSession")
            },
            setSessionPersistenceUncertain: { persistenceUncertain = $0 },
            isSessionPersistenceUncertain: { persistenceUncertain }
        )
        XCTAssertNil(reloadedManager.session)
        XCTAssertEqual(
            reloadedManager.authError,
            "Sign-in blocked: local credential state could not be verified."
        )
        XCTAssertTrue(persistenceUncertain)
    }

    @MainActor
    func testPersistenceMarkerReadFailureBlocksStoredSessionLoad() throws {
        let persistedData = try JSONEncoder().encode(makeSession())
        let authManager = AuthManager(
            apiClient: APIClient(),
            readSessionData: { persistedData },
            removeSessionData: {},
            setSessionPersistenceUncertain: { _ in },
            isSessionPersistenceUncertain: {
                throw KeychainStoreError.operationFailed(
                    "read",
                    key: "authSessionPersistenceUncertain",
                    status: errSecAuthFailed
                )
            }
        )

        XCTAssertNil(authManager.session)
        XCTAssertEqual(
            authManager.authError,
            "Sign-in blocked: local credential state could not be verified."
        )
    }

    @MainActor
    func testMarkerDeletionAmbiguityAndRollbackFailureStillBlockReload() {
        let harness = AmbiguousPersistenceHarness()
        let authManager = makeAmbiguousPersistenceManager(harness)

        XCTAssertThrowsError(try authManager.persistSession(makeSession())) { error in
            XCTAssertEqual(error as? AuthSessionPersistenceError, .rollbackFailed)
        }
        XCTAssertNotNil(harness.persistedData)
        XCTAssertFalse(harness.keychainMarkerPresent)
        XCTAssertTrue(harness.independentSentinelPresent)

        let reloadedManager = makeAmbiguousPersistenceManager(harness)
        XCTAssertNil(reloadedManager.session)
        XCTAssertEqual(
            reloadedManager.authError,
            "Sign-in blocked: local credential state could not be verified."
        )
        XCTAssertTrue(harness.independentSentinelPresent)
    }

    @MainActor
    func testCancelledRefreshDoesNotClearOrReplaceANewerSession() async throws {
        let harness = makeDeferredRefreshHarness()
        defer { DeferredAuthURLProtocol.requestHandler = nil }
        let authManager = makeDeferredAuthManager()
        authManager.session = makeSession(accessToken: makeAuthJWT(expiresIn: -60))

        let refreshTask = Task { await authManager.refreshIfNeeded() }
        await fulfillment(of: [harness.refreshStarted], timeout: 1.0)

        authManager.signOut()
        await fulfillment(of: [harness.logoutCompleted], timeout: 1.0)
        let replacementSession = makeSession(
            refreshToken: "new-sign-in-refresh-token",
            userId: "student-2"
        )
        authManager.session = replacementSession
        try XCTUnwrap(harness.deferredRefresh).respond(
            statusCode: 200,
            data: refreshedTokenResponse()
        )
        await refreshTask.value

        XCTAssertEqual(authManager.session?.refreshToken, replacementSession.refreshToken)
        XCTAssertEqual(authManager.session?.userId, replacementSession.userId)
    }

    @MainActor
    private func makeDeferredRefreshHarness() -> DeferredRefreshHarness {
        let harness = DeferredRefreshHarness(
            refreshStarted: expectation(description: "refresh request started"),
            logoutCompleted: expectation(description: "logout request completed")
        )
        DeferredAuthURLProtocol.requestHandler = { protocolInstance, request in
            switch request.url?.path {
            case "/auth/refresh":
                harness.deferredRefresh = protocolInstance
                harness.refreshStarted.fulfill()
            case "/auth/logout":
                protocolInstance.respond(statusCode: 200, data: Data("{\"success\":true}".utf8))
                harness.logoutCompleted.fulfill()
            default:
                XCTFail("Unexpected or missing request path")
            }
        }
        return harness
    }

    @MainActor
    private func makeDeferredAuthManager() -> AuthManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredAuthURLProtocol.self]
        return AuthManager(
            apiClient: APIClient(session: URLSession(configuration: configuration)),
            removeSessionData: {}
        )
    }

    @MainActor
    private func makeAmbiguousPersistenceManager(
        _ harness: AmbiguousPersistenceHarness
    ) -> AuthManager {
        AuthManager(
            apiClient: APIClient(),
            storeSessionData: { harness.persistedData = $0 },
            readSessionData: { harness.persistedData },
            removeSessionData: { try harness.failSessionRemoval() },
            setSessionPersistenceUncertain: { try harness.setPersistenceUncertain($0) },
            isSessionPersistenceUncertain: { harness.isPersistenceUncertain }
        )
    }

    private func makeSession(
        accessToken: String = makeAuthJWT(expiresIn: 3_600),
        refreshToken: String = "refresh-token",
        userId: String = "student-1"
    ) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId,
            displayName: "Student",
            globalRole: "student"
        )
    }

    private func refreshedTokenResponse() -> Data {
        Data(
            "{\"accessToken\":\"\(makeAuthJWT(expiresIn: 3_600))\",\"refreshToken\":\"replacement-token\"}".utf8
        )
    }
}

private final class AmbiguousPersistenceHarness {
    var persistedData: Data?
    var keychainMarkerPresent = false
    var independentSentinelPresent = false
    private var clearAttempts = 0

    var isPersistenceUncertain: Bool {
        independentSentinelPresent || keychainMarkerPresent
    }

    func setPersistenceUncertain(_ uncertain: Bool) throws {
        if uncertain {
            independentSentinelPresent = true
            keychainMarkerPresent = true
            return
        }
        keychainMarkerPresent = false
        clearAttempts += 1
        if clearAttempts == 1 {
            throw KeychainStoreError.operationFailed(
                "read",
                key: "authSessionPersistenceUncertain",
                status: errSecAuthFailed
            )
        }
        independentSentinelPresent = false
    }

    func failSessionRemoval() throws {
        throw KeychainStoreError.removalVerificationFailed("authSession")
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

private final class DeferredAuthURLProtocol: URLProtocol {
    static var requestHandler: ((DeferredAuthURLProtocol, URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func makeAuthJWT(expiresIn: TimeInterval) -> String {
    let header = authBase64URLString(from: Data("{\"alg\":\"none\"}".utf8))
    let expiration = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
    let payload = authBase64URLString(from: Data("{\"exp\":\(expiration)}".utf8))
    return "\(header).\(payload).signature"
}

private func authBase64URLString(from data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
