import Foundation
import os
import SwiftData

// Creates resilient SwiftData containers and provides explicit local alpha-data reset behavior.

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "Persistence")

@MainActor
/// Builds the model container with a recoverable reset path for incompatible local stores.
enum PersistenceController {
    static let shared: Result<ModelContainer, Error> = createPersistentContainer()

    // Used by tests and screenshot builds.
    static func createContainer(inMemory: Bool = false) -> ModelContainer {
        do {
            let container = try makeContainer(inMemory: inMemory)
            // Test and preview containers deliberately do not touch persistent
            // credentials, defaults, media, or calendar state.
            if !inMemory {
                try LocalAlphaDataReset.runIfNeeded(modelContext: container.mainContext, environment: .live())
            }
            return container
        } catch {
            logger.fault("Failed to create ModelContainer: \(error.localizedDescription)")
            fatalError("Unable to create ModelContainer: \(error)")
        }
    }

    private static func createPersistentContainer() -> Result<ModelContainer, Error> {
        openPersistentContainer(clearingLeftoverSignIn: false)
    }

    /// User-directed recovery for a sign-in left behind by an earlier installation with no stored data.
    static func createPersistentContainerClearingLeftoverSignIn() -> Result<ModelContainer, Error> {
        openPersistentContainer(clearingLeftoverSignIn: true)
    }

    private static func openPersistentContainer(clearingLeftoverSignIn: Bool) -> Result<ModelContainer, Error> {
        do {
            let container = try makeContainer(inMemory: false)
            try LocalAlphaDataReset.runIfNeeded(
                modelContext: container.mainContext,
                environment: .live(),
                clearingLeftoverSignIn: clearingLeftoverSignIn
            )
            repairStoredMediaPaths(in: container.mainContext)
            return .success(container)
        } catch {
            logger.fault("Failed to create persistent ModelContainer: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    /// Rewrites absolute media paths that point into a previous app container.
    private static func repairStoredMediaPaths(in modelContext: ModelContext) {
        do {
            let artifacts = try modelContext.fetch(
                FetchDescriptor<LocalArtifact>(predicate: #Predicate { !$0.localPath.isEmpty })
            )
            var repaired = 0
            for artifact in artifacts {
                if let relocated = FileStore.relocatedMediaPath(forStoredPath: artifact.localPath) {
                    artifact.localPath = relocated
                    repaired += 1
                }
            }
            if repaired > 0 { try modelContext.save() }
            logger.info("Repaired \(repaired) stored media paths")
        } catch {
            logger.error("Failed to repair stored media paths: \(error.localizedDescription)")
        }
    }

    private static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: modelSchema(), configurations: [config])
    }

    /// The single list of SwiftData model types, ordered parents before children.
    static let modelTypes: [any PersistentModel.Type] = [
        LocalCourse.self,
        LocalPracticeEntry.self,
        LocalArtifact.self,
        LocalFeedback.self,
        LocalMarker.self,
        LocalCaptureMarker.self,
        SyncQueueItem.self,
        CalendarEvent.self
    ]

    /// Destructive paths remove children before the parents that reference them.
    static var deletionOrder: [any PersistentModel.Type] {
        modelTypes.reversed()
    }

    static func modelSchema() -> Schema {
        Schema(modelTypes)
    }
}

extension ModelContext {
    /// Deletes every stored instance of each type in order without saving.
    func deleteAllModels(of types: [any PersistentModel.Type]) throws {
        for type in types {
            try deleteModels(type)
        }
    }

    func containsModels(of types: [any PersistentModel.Type]) throws -> Bool {
        try types.contains { try containsModels($0) }
    }

    private func deleteModels<T: PersistentModel>(_ type: T.Type) throws {
        for model in try fetch(FetchDescriptor<T>()) {
            delete(model)
        }
    }

    private func containsModels<T: PersistentModel>(_ type: T.Type) throws -> Bool {
        try !fetch(FetchDescriptor<T>()).isEmpty
    }
}

/// Installed-alpha persisted-data migration boundary for the intentionally breaking baseline. The
/// generation marker is written only after every data surface has been removed
/// and verified, so a failed cleanup is retried on the next persistent launch.
@MainActor
/// Deletes all locally persisted profile data and media after callers have stopped synchronization.
enum LocalAlphaDataReset {
    static let generation = "0.1.0-alpha.1"
    /// Only this known predecessor may be destructively migrated. Any other
    /// marker could represent newer or corrupted local data and must recover
    /// through an explicit user-directed path instead.
    static let knownPredecessorGenerations: Set<String> = ["pre-alpha"]

    struct Environment {
        let readGeneration: () throws -> String?
        let writeGeneration: (String) throws -> Void
        let removeStoredMedia: () throws -> Void
        let hasStoredMedia: () throws -> Bool
        let removeCalendarSubscription: () throws -> Void
        let localDataOwner: () throws -> String?
        let removeLocalDataOwner: () throws -> Void
        let removePersistedAuth: () throws -> Void

        @MainActor
        static func live() -> Environment {
            Environment(
            readGeneration: {
                UserDefaults.standard.string(forKey: "localDataGeneration")
            },
            writeGeneration: { generation in
                UserDefaults.standard.set(generation, forKey: "localDataGeneration")
            },
            removeStoredMedia: {
                try FileStore.removeAllStoredMediaFiles()
            },
            hasStoredMedia: {
                try FileStore.hasStoredMediaFiles()
            },
            removeCalendarSubscription: {
                try CalendarSubscriptionStore.removeStoredURL()
            },
            localDataOwner: {
                try KeychainStore.read("localDataOwnerId")
            },
            removeLocalDataOwner: {
                try KeychainStore.removeStoredValue(for: "localDataOwnerId")
            },
            removePersistedAuth: {
                try AuthManager.clearPersistedSessionForLocalReset()
            }
            )
        }
    }

    static func runIfNeeded(
        modelContext: ModelContext,
        environment: Environment,
        clearingLeftoverSignIn: Bool = false
    ) throws {
        let recordedGeneration = try environment.readGeneration()
        guard recordedGeneration != generation else { return }
        if let recordedGeneration, !knownPredecessorGenerations.contains(recordedGeneration) {
            throw LocalAlphaDataResetError.ambiguousExistingData
        }
        if recordedGeneration == nil {
            let hasExistingSwiftData = try containsAnyModels(in: modelContext)
            let hasExistingMedia = try environment.hasStoredMedia()
            let hasExistingOwner = try environment.localDataOwner() != nil
            guard !hasExistingSwiftData, !hasExistingMedia else {
                throw LocalAlphaDataResetError.ambiguousExistingData
            }
            if hasExistingOwner, !clearingLeftoverSignIn {
                throw LocalAlphaDataResetError.leftoverSignInOnly
            }
        }

        try environment.removePersistedAuth()
        try removeSwiftDataModels(from: modelContext)
        try environment.removeStoredMedia()
        guard try !environment.hasStoredMedia() else {
            throw LocalAlphaDataResetError.mediaStillExists
        }
        try environment.removeCalendarSubscription()
        try environment.removeLocalDataOwner()
        guard try environment.localDataOwner() == nil else {
            throw LocalAlphaDataResetError.localDataOwnerStillExists
        }
        try environment.writeGeneration(generation)
        guard try environment.readGeneration() == generation else {
            throw LocalAlphaDataResetError.generationWriteVerificationFailed
        }
    }

    private static func removeSwiftDataModels(from modelContext: ModelContext) throws {
        try modelContext.deleteAllModels(of: PersistenceController.deletionOrder)
        try modelContext.save()

        guard try !containsAnyModels(in: modelContext) else {
            throw LocalAlphaDataResetError.swiftDataModelsStillExist
        }
    }

    private static func containsAnyModels(in modelContext: ModelContext) throws -> Bool {
        try modelContext.containsModels(of: PersistenceController.deletionOrder)
    }
}

enum LocalAlphaDataResetError: LocalizedError, Equatable {
    case ambiguousExistingData
    case leftoverSignInOnly
    case swiftDataModelsStillExist
    case mediaStillExists
    case localDataOwnerStillExists
    case generationWriteVerificationFailed

    var errorDescription: String? {
        switch self {
        case .ambiguousExistingData:
            return "Existing local data needs recovery before this alpha reset can continue."
        case .leftoverSignInOnly:
            return "Sign-in data from an earlier installation must be cleared before Resonance can start."
        case .swiftDataModelsStillExist:
            return "Local data could not be reset safely."
        case .mediaStillExists:
            return "Stored media could not be reset safely."
        case .localDataOwnerStillExists:
            return "The local data owner could not be reset safely."
        case .generationWriteVerificationFailed:
            return "The local data reset could not be recorded safely."
        }
    }
}
