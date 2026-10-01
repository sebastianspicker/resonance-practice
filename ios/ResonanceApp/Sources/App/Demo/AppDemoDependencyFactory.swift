import Foundation

/// Keeps screenshot-only persistence and authentication behavior out of the
/// production composition root while retaining deterministic demo scenarios.
@MainActor
enum AppDemoDependencyFactory {
    static func makeAuthManager(client: APIClient) -> AuthManager {
#if RESONANCE_SCREENSHOTS
        if ScreenshotScenario.current != nil {
            return AuthManager(
                apiClient: client,
                storeSessionData: { _ in },
                readSessionData: { nil },
                removeSessionData: {},
                setSessionPersistenceUncertain: { _ in },
                isSessionPersistenceUncertain: { false }
            )
        }
#endif
        return AuthManager(apiClient: client)
    }

    static func makeLocalDataOwnerStore() -> LocalDataOwnerStore {
#if RESONANCE_SCREENSHOTS
        if let scenario = ScreenshotScenario.current {
            let userId = scenario.persona == .teacher
                ? DemoConfiguration.screenshotTeacherUserId
                : DemoConfiguration.screenshotStudentUserId
            return LocalDataOwnerStore(
                read: { userId },
                write: { _ in },
                remove: {}
            )
        }
#endif
        return KeychainStore.localDataOwnerStore()
    }
}
