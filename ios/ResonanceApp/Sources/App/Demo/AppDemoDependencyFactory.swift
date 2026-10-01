import Foundation

/// Keeps screenshot-only persistence and authentication behavior out of the
/// production composition root while retaining deterministic demo scenarios.
@MainActor
enum AppDemoDependencyFactory {
    static func makeAuthManager(client: APIClient) -> AuthManager {
        guard screenshotScenario != nil else { return AuthManager(apiClient: client) }
        return AuthManager(
            apiClient: client,
            storeSessionData: { _ in },
            readSessionData: { nil },
            removeSessionData: {},
            setSessionPersistenceUncertain: { _ in },
            isSessionPersistenceUncertain: { false }
        )
    }

    static func makeLocalDataOwnerStore(
        read: (() throws -> String?)?,
        write: ((String) throws -> Void)?,
        remove: (() throws -> Void)?
    ) -> LocalDataOwnerStore {
        guard let scenario = screenshotScenario else {
            let defaults = KeychainStore.localDataOwnerStore()
            return LocalDataOwnerStore(
                read: read ?? defaults.read,
                write: write ?? defaults.write,
                remove: remove ?? defaults.remove
            )
        }

        let userId = scenario.persona == .teacher
            ? DemoConfiguration.screenshotTeacherUserId
            : DemoConfiguration.screenshotStudentUserId
        return LocalDataOwnerStore(
            read: read ?? { userId },
            write: write ?? { _ in },
            remove: remove ?? {}
        )
    }

    private static var screenshotScenario: ScreenshotScenario? {
#if RESONANCE_SCREENSHOTS
        ScreenshotScenario.current
#else
        nil
#endif
    }
}
