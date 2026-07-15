import Foundation
import SwiftData

@MainActor
final class AppState: ObservableObject {
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
        removeLocalDataOwner: (() throws -> Void)? = nil
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
        let client = APIClient()
        self.apiClient = client
#if RESONANCE_SCREENSHOTS
        let screenshotScenario = ScreenshotScenario.current
#else
        let screenshotScenario: ScreenshotScenario? = nil
#endif
        if let screenshotScenario {
            let screenshotUserId = screenshotScenario.persona == .teacher
                ? AppConfig.screenshotTeacherUserId
                : AppConfig.screenshotStudentUserId
            self.localDataOwner = localDataOwner ?? { screenshotUserId }
            self.setLocalDataOwner = setLocalDataOwner ?? { _ in }
            self.removeLocalDataOwner = removeLocalDataOwner ?? {}
        } else {
            self.localDataOwner = localDataOwner ?? {
                try KeychainStore.read("localDataOwnerId")
            }
            self.setLocalDataOwner = setLocalDataOwner ?? { userId in
                try KeychainStore.store(userId, for: "localDataOwnerId")
            }
            self.removeLocalDataOwner = removeLocalDataOwner ?? {
                try KeychainStore.removeStoredValue(for: "localDataOwnerId")
            }
        }
        let auth: AuthManager
        if screenshotScenario != nil {
            auth = AuthManager(
                apiClient: client,
                storeSessionData: { _ in },
                readSessionData: { nil },
                removeSessionData: {},
                setSessionPersistenceUncertain: { _ in },
                isSessionPersistenceUncertain: { false }
            )
        } else {
            auth = AuthManager(apiClient: client)
        }
        self.authManager = auth
        let net = NetworkMonitor()
        self.networkMonitor = net
        self.syncManager = SyncManager(modelContext: modelContext, authManager: auth, apiClient: client, networkMonitor: net)
    }

    func activateLocalProfile(userId: String) throws -> Bool {
        let previousOwner = try localDataOwner()
        if let previousOwner, previousOwner != userId {
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

    func replaceLocalProfile(with userId: String) throws {
        try purgeLocalUserData()
        try setLocalDataOwner(userId)
        guard try localDataOwner() == userId else {
            throw AppStateError.localDataOwnerVerificationFailed
        }
    }

    func signOutAndDeleteLocalData() {
        do {
            try purgeLocalUserData()
            try removeLocalDataOwner()
            guard try localDataOwner() == nil else {
                throw AppStateError.localDataOwnerRemovalVerificationFailed
            }
            authManager.signOut()
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
