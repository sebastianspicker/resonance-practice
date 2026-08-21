import Foundation
import SwiftData

// Owns local-profile admission, destructive replacement, and sign-out persistence ordering.
@MainActor
struct AppStateLocalProfileLifecycle {
    let dependencies: AppStateLocalProfileDependencies
    let invalidateProcessing: () -> Void
    let cancelAndWaitForProcessing: () async -> Void

    func activate(userId: String) throws -> Bool {
        let previousOwner = try dependencies.localDataOwner()
        if let previousOwner, previousOwner != userId {
            invalidateProcessing()
            return false
        }
        if previousOwner == nil {
            guard try hasNoLegacyLocalData() else {
                return false
            }
        }
        try dependencies.setLocalDataOwner(userId)
        guard try dependencies.localDataOwner() == userId else {
            throw AppStateError.localDataOwnerVerificationFailed
        }
        return true
    }

    func replace(with userId: String) async throws {
        await cancelAndWaitForProcessing()
        try purgeLocalUserData()
        try dependencies.setLocalDataOwner(userId)
        guard try dependencies.localDataOwner() == userId else {
            throw AppStateError.localDataOwnerVerificationFailed
        }
    }

    func signOutAndDeleteLocalData() async throws {
        await cancelAndWaitForProcessing()
        let signedOutSession = try dependencies.clearLocalCredentials()
        defer { dependencies.revokeRemoteSession(signedOutSession) }
        try purgeLocalUserData()
        try dependencies.removeLocalDataOwner()
        guard try dependencies.localDataOwner() == nil else {
            throw AppStateError.localDataOwnerRemovalVerificationFailed
        }
    }

    private func purgeLocalUserData() throws {
        try dependencies.removeStoredMediaFiles()
        try deleteAll(CalendarEvent.self)
        try deleteAll(SyncQueueItem.self)
        try deleteAll(LocalCaptureMarker.self)
        try deleteAll(LocalMarker.self)
        try deleteAll(LocalFeedback.self)
        try deleteAll(LocalArtifact.self)
        try deleteAll(LocalPracticeEntry.self)
        try deleteAll(LocalCourse.self)
        try dependencies.saveChanges()
        try verifyNoLocalUserData()
        try dependencies.removeCalendarSubscription()
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type) throws {
        let models = try dependencies.modelContext.fetch(FetchDescriptor<T>())
        for model in models { dependencies.modelContext.delete(model) }
    }

    private func verifyNoLocalUserData() throws {
        guard try hasNoLegacyLocalData() else {
            throw AppStateError.localDataStillExists("local profile")
        }
    }

    private func hasNoLegacyLocalData() throws -> Bool {
        if try dependencies.hasStoredMediaFiles() {
            return false
        }
        guard try dependencies.fetchArtifacts().isEmpty else { return false }
        return try !containsModels(CalendarEvent.self) &&
            !containsModels(SyncQueueItem.self) &&
            !containsModels(LocalCaptureMarker.self) &&
            !containsModels(LocalMarker.self) &&
            !containsModels(LocalFeedback.self) &&
            !containsModels(LocalPracticeEntry.self) &&
            !containsModels(LocalCourse.self)
    }

    private func containsModels<T: PersistentModel>(_ type: T.Type) throws -> Bool {
        try !dependencies.modelContext.fetch(FetchDescriptor<T>()).isEmpty
    }
}

@MainActor
struct AppStateLocalProfileDependencies {
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

    func makeLifecycle(
        invalidateProcessing: @escaping () -> Void,
        cancelAndWaitForProcessing: @escaping () async -> Void
    ) -> AppStateLocalProfileLifecycle {
        AppStateLocalProfileLifecycle(
            dependencies: self,
            invalidateProcessing: invalidateProcessing,
            cancelAndWaitForProcessing: cancelAndWaitForProcessing
        )
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
