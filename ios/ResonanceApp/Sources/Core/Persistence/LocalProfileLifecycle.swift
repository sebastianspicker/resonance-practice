import Foundation
import SwiftData

// Owns local-profile admission, destructive replacement, and sign-out persistence ordering.
@MainActor
struct LocalProfileLifecycle {
    /// Every effect the lifecycle performs, injected so ordering and fail-closed behavior are testable.
    struct Dependencies {
        let modelContext: ModelContext
        let fetchArtifacts: () throws -> [LocalArtifact]
        let saveChanges: () throws -> Void
        let removeStoredMediaFiles: () throws -> Void
        let hasStoredMediaFiles: () throws -> Bool
        let removeCalendarSubscription: () throws -> Void
        let localDataOwner: () throws -> String?
        let setLocalDataOwner: (String) throws -> Void
        let removeLocalDataOwner: () throws -> Void
        let clearLocalCredentials: () throws -> AuthSession?
        let revokeRemoteSession: (AuthSession?) -> Void
        let invalidateProcessing: () -> Void
        let cancelAndWaitForProcessing: () async -> Void
    }

    let dependencies: Dependencies

    /// Wires the lifecycle to the production stores, credentials, and sync manager.
    static func live(
        modelContext: ModelContext,
        ownerStore: LocalDataOwnerStore,
        authManager: AuthManager,
        syncManager: SyncManager
    ) -> LocalProfileLifecycle {
        LocalProfileLifecycle(dependencies: Dependencies(
            modelContext: modelContext,
            fetchArtifacts: { try modelContext.fetch(FetchDescriptor<LocalArtifact>()) },
            saveChanges: { try modelContext.save() },
            removeStoredMediaFiles: { try FileStore.removeAllStoredMediaFiles() },
            hasStoredMediaFiles: { try FileStore.hasStoredMediaFiles() },
            removeCalendarSubscription: { try CalendarSubscriptionStore.removeStoredURL() },
            localDataOwner: ownerStore.read,
            setLocalDataOwner: ownerStore.write,
            removeLocalDataOwner: ownerStore.remove,
            clearLocalCredentials: { try authManager.clearLocalSessionReturningPreviousSession() },
            revokeRemoteSession: { authManager.revokeRemoteSession($0) },
            invalidateProcessing: { syncManager.invalidateProcessing() },
            cancelAndWaitForProcessing: { await syncManager.cancelAndWaitForProcessing() }
        ))
    }

    func activate(userId: String) throws -> Bool {
        let previousOwner = try dependencies.localDataOwner()
        if let previousOwner, previousOwner != userId {
            dependencies.invalidateProcessing()
            return false
        }
        if previousOwner == nil {
            guard try hasNoLegacyLocalData() else {
                return false
            }
        }
        try dependencies.setLocalDataOwner(userId)
        guard try dependencies.localDataOwner() == userId else {
            throw LocalProfileLifecycleError.localDataOwnerVerificationFailed
        }
        return true
    }

    /// Cancels sync and erases the prior owner's local records before establishing a new owner.
    func replace(with userId: String) async throws {
        await dependencies.cancelAndWaitForProcessing()
        try purgeLocalUserData()
        try dependencies.setLocalDataOwner(userId)
        guard try dependencies.localDataOwner() == userId else {
            throw LocalProfileLifecycleError.localDataOwnerVerificationFailed
        }
    }

    /// Performs the destructive sign-out path after in-flight sync work has been quiesced.
    func signOutAndDeleteLocalData() async throws {
        await dependencies.cancelAndWaitForProcessing()
        let signedOutSession = try dependencies.clearLocalCredentials()
        defer { dependencies.revokeRemoteSession(signedOutSession) }
        try purgeLocalUserData()
        try dependencies.removeLocalDataOwner()
        guard try dependencies.localDataOwner() == nil else {
            throw LocalProfileLifecycleError.localDataOwnerRemovalVerificationFailed
        }
    }

    private func purgeLocalUserData() throws {
        try dependencies.removeStoredMediaFiles()
        try dependencies.modelContext.deleteAllModels(of: PersistenceController.deletionOrder)
        try dependencies.saveChanges()
        try verifyNoLocalUserData()
        try dependencies.removeCalendarSubscription()
    }

    private func verifyNoLocalUserData() throws {
        guard try hasNoLegacyLocalData() else {
            throw LocalProfileLifecycleError.localDataStillExists("local profile")
        }
    }

    private func hasNoLegacyLocalData() throws -> Bool {
        if try dependencies.hasStoredMediaFiles() {
            return false
        }
        guard try dependencies.fetchArtifacts().isEmpty else { return false }
        // Artifacts are probed through the injected fetch above.
        let remainingTypes = PersistenceController.deletionOrder.filter {
            ObjectIdentifier($0) != ObjectIdentifier(LocalArtifact.self)
        }
        return try !dependencies.modelContext.containsModels(of: remainingTypes)
    }
}

enum LocalProfileLifecycleError: LocalizedError {
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
