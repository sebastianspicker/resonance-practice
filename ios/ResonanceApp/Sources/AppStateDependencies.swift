import Foundation
import SwiftData

// Resolves app-wide defaults and screenshot-safe services without weakening AppState injection seams.
@MainActor
struct AppStateLocalProfileOverrides {
    let fetchArtifacts: (() throws -> [LocalArtifact])? = nil
    let saveChanges: (() throws -> Void)? = nil
    let removeStoredMediaFiles: (() throws -> Void)? = nil
    let hasStoredMediaFiles: (() throws -> Bool)? = nil
    let removeCalendarSubscription: (() throws -> Void)? = nil
    let localDataOwner: (() throws -> String?)? = nil
    let setLocalDataOwner: ((String) throws -> Void)? = nil
    let removeLocalDataOwner: (() throws -> Void)? = nil
    let clearLocalCredentials: (() throws -> AuthSession?)? = nil
    let revokeRemoteSession: ((AuthSession?) -> Void)? = nil
}

@MainActor
struct AppStateConfiguration {
    let modelContext: ModelContext
    let localProfileOverrides: AppStateLocalProfileOverrides
    let apiClient: APIClient?
    let networkMonitor: NetworkMonitor?
}

@MainActor
struct AppStateDependencies {
    let apiClient: APIClient
    let authManager: AuthManager
    let syncManager: SyncManager
    let networkMonitor: NetworkMonitor
    let localProfileDependencies: AppStateLocalProfileDependencies

    init(configuration: AppStateConfiguration) {
        let modelContext = configuration.modelContext
        let localProfileOverrides = configuration.localProfileOverrides
        let client = configuration.apiClient ?? APIClient()
        self.apiClient = client
        let screenshotScenario = Self.screenshotScenario
        let auth = Self.makeAuthManager(client: client, screenshotScenario: screenshotScenario)
        self.authManager = auth
        let localProfileDependencies = Self.makeLocalProfileDependencies(
            modelContext: modelContext,
            overrides: localProfileOverrides,
            auth: auth,
            screenshotScenario: screenshotScenario
        )
        self.localProfileDependencies = localProfileDependencies
        let network = configuration.networkMonitor ?? NetworkMonitor()
        self.networkMonitor = network
        self.syncManager = SyncManager(
            modelContext: localProfileDependencies.modelContext,
            authManager: auth,
            apiClient: client,
            networkMonitor: network,
            verifiedOwner: localProfileDependencies.localDataOwner
        )
    }

    private static func makeLocalProfileDependencies(
        modelContext: ModelContext,
        overrides: AppStateLocalProfileOverrides,
        auth: AuthManager,
        screenshotScenario: ScreenshotScenario?
    ) -> AppStateLocalProfileDependencies {
        let ownerStore = localDataOwnerStore(
            scenario: screenshotScenario,
            read: overrides.localDataOwner,
            write: overrides.setLocalDataOwner,
            remove: overrides.removeLocalDataOwner
        )
        let clearLocalCredentials = overrides.clearLocalCredentials ?? {
            try auth.clearLocalSessionReturningPreviousSession()
        }
        let revokeRemoteSession = overrides.revokeRemoteSession ?? { auth.revokeRemoteSession($0) }
        return AppStateLocalProfileDependencies(
            modelContext: modelContext,
            fetchArtifacts: overrides.fetchArtifacts ?? { try modelContext.fetch(FetchDescriptor<LocalArtifact>()) },
            saveChanges: overrides.saveChanges ?? { try modelContext.save() },
            removeStoredMediaFiles: overrides.removeStoredMediaFiles ?? { try FileStore.removeAllStoredMediaFiles() },
            hasStoredMediaFiles: overrides.hasStoredMediaFiles ?? { try FileStore.hasStoredMediaFiles() },
            removeCalendarSubscription: overrides.removeCalendarSubscription ?? { try CalendarSubscriptionStore.removeStoredURL() },
            localDataOwner: ownerStore.read,
            setLocalDataOwner: ownerStore.write,
            removeLocalDataOwner: ownerStore.remove,
            clearLocalCredentials: clearLocalCredentials,
            revokeRemoteSession: revokeRemoteSession
        )
    }

    private static var screenshotScenario: ScreenshotScenario? {
#if RESONANCE_SCREENSHOTS
        ScreenshotScenario.current
#else
        nil
#endif
    }

    private static func localDataOwnerStore(
        scenario: ScreenshotScenario?,
        read: (() throws -> String?)?,
        write: ((String) throws -> Void)?,
        remove: (() throws -> Void)?
    ) -> LocalDataOwnerStore {
        guard let scenario else {
            let defaults = KeychainStore.localDataOwnerStore()
            return LocalDataOwnerStore(
                read: read ?? defaults.read,
                write: write ?? defaults.write,
                remove: remove ?? defaults.remove
            )
        }
        let userId = scenario.persona == .teacher ? AppConfig.screenshotTeacherUserId : AppConfig.screenshotStudentUserId
        return LocalDataOwnerStore(read: read ?? { userId }, write: write ?? { _ in }, remove: remove ?? {})
    }

    private static func makeAuthManager(client: APIClient, screenshotScenario: ScreenshotScenario?) -> AuthManager {
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

    func makeLocalProfileLifecycle(syncManager: SyncManager) -> AppStateLocalProfileLifecycle {
        localProfileDependencies.makeLifecycle(
            invalidateProcessing: { syncManager.invalidateProcessing() },
            cancelAndWaitForProcessing: { await syncManager.cancelAndWaitForProcessing() }
        )
    }
}
