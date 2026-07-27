import Foundation
import SwiftData

// Coordinates app-wide dependencies and profile-bound local-data lifecycle transitions.
@MainActor
final class AppState: ObservableObject {
    private struct OwnerActions {
        let read: () throws -> String?
        let write: (String) throws -> Void
        let remove: () throws -> Void
    }
    let apiClient: APIClient
    let authManager: AuthManager
    let syncManager: SyncManager
    let networkMonitor: NetworkMonitor
    private let modelContext: ModelContext
    private let fetchArtifacts: () throws -> [LocalArtifact]
    private let saveChanges: () throws -> Void
    private let removeStoredMediaFiles: () throws -> Void
    private let hasStoredMediaFiles: () throws -> Bool
    private let removeCalendarSubscription: () throws -> Void
    private let localDataOwner: () throws -> String?
    private let setLocalDataOwner: (String) throws -> Void
    private let removeLocalDataOwner: () throws -> Void
    private let clearLocalCredentials: () throws -> AuthSession?
    private let revokeRemoteSession: (AuthSession?) -> Void

    @Published var lastErrorMessage: String?
    @Published var showErrorAlert: Bool = false

    init(
        modelContext: ModelContext,
        fetchArtifacts: (() throws -> [LocalArtifact])? = nil,
        saveChanges: (() throws -> Void)? = nil,
        removeStoredMediaFiles: (() throws -> Void)? = nil,
        hasStoredMediaFiles: (() throws -> Bool)? = nil,
        removeCalendarSubscription: (() throws -> Void)? = nil,
        localDataOwner: (() throws -> String?)? = nil,
        setLocalDataOwner: ((String) throws -> Void)? = nil,
        removeLocalDataOwner: (() throws -> Void)? = nil,
        clearLocalCredentials: (() throws -> AuthSession?)? = nil,
        revokeRemoteSession: ((AuthSession?) -> Void)? = nil,
        apiClient: APIClient? = nil,
        networkMonitor: NetworkMonitor? = nil
    ) {
        self.modelContext = modelContext
        self.fetchArtifacts = fetchArtifacts ?? {
            try modelContext.fetch(FetchDescriptor<LocalArtifact>())
        }
        self.saveChanges = saveChanges ?? {
            try modelContext.save()
        }
        self.removeStoredMediaFiles = removeStoredMediaFiles ?? {
            try FileStore.removeAllStoredMediaFiles()
        }
        self.hasStoredMediaFiles = hasStoredMediaFiles ?? {
            try FileStore.hasStoredMediaFiles()
        }
        self.removeCalendarSubscription = removeCalendarSubscription ?? {
            try CalendarSubscriptionStore.removeStoredURL()
        }
        let client = apiClient ?? APIClient()
        self.apiClient = client
        let screenshotScenario = Self.screenshotScenario
        let ownerActions = Self.ownerActions(
            scenario: screenshotScenario,
            read: localDataOwner,
            write: setLocalDataOwner,
            remove: removeLocalDataOwner
        )
        self.localDataOwner = ownerActions.read
        self.setLocalDataOwner = ownerActions.write
        self.removeLocalDataOwner = ownerActions.remove
        let auth = Self.makeAuthManager(client: client, screenshotScenario: screenshotScenario)
        self.authManager = auth
        self.clearLocalCredentials = clearLocalCredentials ?? {
            try auth.clearLocalSessionReturningPreviousSession()
        }
        self.revokeRemoteSession = revokeRemoteSession ?? { auth.revokeRemoteSession($0) }
        let net = networkMonitor ?? NetworkMonitor()
        self.networkMonitor = net
        self.syncManager = SyncManager(
            modelContext: modelContext,
            authManager: auth,
            apiClient: client,
            networkMonitor: net,
            verifiedOwner: self.localDataOwner
        )
    }

    private static var screenshotScenario: ScreenshotScenario? {
#if RESONANCE_SCREENSHOTS
        ScreenshotScenario.current
#else
        nil
#endif
    }

    private static func ownerActions(
        scenario: ScreenshotScenario?,
        read: (() throws -> String?)?,
        write: ((String) throws -> Void)?,
        remove: (() throws -> Void)?
    ) -> OwnerActions {
        guard let scenario else {
            return OwnerActions(
                read: read ?? { try KeychainStore.read("localDataOwnerId") },
                write: write ?? { try KeychainStore.store($0, for: "localDataOwnerId") },
                remove: remove ?? { try KeychainStore.removeStoredValue(for: "localDataOwnerId") }
            )
        }
        let userId = scenario.persona == .teacher ? AppConfig.screenshotTeacherUserId : AppConfig.screenshotStudentUserId
        return OwnerActions(read: read ?? { userId }, write: write ?? { _ in }, remove: remove ?? {})
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

    func activateLocalProfile(userId: String) throws -> Bool {
        let previousOwner = try localDataOwner()
        if let previousOwner, previousOwner != userId {
            syncManager.invalidateProcessing()
            return false
        }
        if previousOwner == nil {
            guard try hasNoLegacyLocalData() else {
                return false
            }
        }
        try setLocalDataOwner(userId)
        guard try localDataOwner() == userId else {
            throw AppStateError.localDataOwnerVerificationFailed
        }
        return true
    }

    /// Cancels sync and erases the prior owner's local records before establishing a new owner.
    func replaceLocalProfile(with userId: String) async throws {
        await syncManager.cancelAndWaitForProcessing()
        try purgeLocalUserData()
        try setLocalDataOwner(userId)
        guard try localDataOwner() == userId else {
            throw AppStateError.localDataOwnerVerificationFailed
        }
    }

    /// Performs the destructive sign-out path after in-flight sync work has been quiesced.
    func signOutAndDeleteLocalData() async {
        do {
            await syncManager.cancelAndWaitForProcessing()
            let signedOutSession = try clearLocalCredentials()
            defer { revokeRemoteSession(signedOutSession) }
            try purgeLocalUserData()
            try removeLocalDataOwner()
            guard try localDataOwner() == nil else {
                throw AppStateError.localDataOwnerRemovalVerificationFailed
            }
        } catch {
            reportError(error)
        }
    }

    private func purgeLocalUserData() throws {
        try removeStoredMediaFiles()
        try deleteAll(CalendarEvent.self)
        try deleteAll(SyncQueueItem.self)
        try deleteAll(LocalCaptureMarker.self)
        try deleteAll(LocalMarker.self)
        try deleteAll(LocalFeedback.self)
        try deleteAll(LocalArtifact.self)
        try deleteAll(LocalPracticeEntry.self)
        try deleteAll(LocalCourse.self)
        try saveChanges()
        try verifyNoLocalUserData()
        try removeCalendarSubscription()
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type) throws {
        let models = try modelContext.fetch(FetchDescriptor<T>())
        for model in models { modelContext.delete(model) }
    }

    private func verifyNoLocalUserData() throws {
        guard try hasNoLegacyLocalData() else {
            throw AppStateError.localDataStillExists("local profile")
        }
    }

    private func hasNoLegacyLocalData() throws -> Bool {
        if try hasStoredMediaFiles() {
            return false
        }
        guard try fetchArtifacts().isEmpty else { return false }
        return try !containsModels(CalendarEvent.self) &&
            !containsModels(SyncQueueItem.self) &&
            !containsModels(LocalCaptureMarker.self) &&
            !containsModels(LocalMarker.self) &&
            !containsModels(LocalFeedback.self) &&
            !containsModels(LocalPracticeEntry.self) &&
            !containsModels(LocalCourse.self)
    }

    private func containsModels<T: PersistentModel>(_ type: T.Type) throws -> Bool {
        try !modelContext.fetch(FetchDescriptor<T>()).isEmpty
    }

    func reportError(_ error: Error) {
        if let apiError = error as? APIError {
            lastErrorMessage = apiError.error.message
        } else {
            lastErrorMessage = error.localizedDescription
        }
        showErrorAlert = true
    }

    func clearError() {
        lastErrorMessage = nil
        showErrorAlert = false
    }
}

enum AppStateError: LocalizedError {
    case localDataStillExists(String)
    case localDataOwnerVerificationFailed
    case localDataOwnerRemovalVerificationFailed

    var errorDescription: String? {
        switch self {
        case let .localDataStillExists(type):
            return "Local \(type) data could not be removed."
        case .localDataOwnerVerificationFailed:
            return "The local profile owner could not be saved."
        case .localDataOwnerRemovalVerificationFailed:
            return "The local profile owner could not be removed."
        }
    }
}
