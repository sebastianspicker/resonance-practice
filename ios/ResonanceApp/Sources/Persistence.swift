import Foundation
import os
import SwiftData

// Creates resilient SwiftData containers and provides explicit local alpha-data reset behavior.

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "Persistence")

@MainActor
/// Builds the model container with a recoverable reset path for incompatible local stores.
enum PersistenceController {
    static let shared: Result<ModelContainer, Error> = createPersistentContainer()

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
        do {
            let container = try makeContainer(inMemory: false)
            try LocalAlphaDataReset.runIfNeeded(modelContext: container.mainContext, environment: .live())
            return .success(container)
        } catch {
            logger.fault("Failed to create persistent ModelContainer: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    private static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: modelSchema(), configurations: [config])
    }

    static func modelSchema() -> Schema {
        Schema([
            LocalCourse.self,
            LocalPracticeEntry.self,
            LocalArtifact.self,
            LocalFeedback.self,
            LocalMarker.self,
            LocalCaptureMarker.self,
            SyncQueueItem.self,
            CalendarEvent.self
        ])
    }
}

/// One-time local reset for the intentionally breaking alpha baseline. The
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

    static func runIfNeeded(modelContext: ModelContext, environment: Environment) throws {
        let recordedGeneration = try environment.readGeneration()
        guard recordedGeneration != generation else { return }
        if let recordedGeneration, !knownPredecessorGenerations.contains(recordedGeneration) {
            throw LocalAlphaDataResetError.ambiguousExistingData
        }
        if recordedGeneration == nil {
            let hasExistingSwiftData = try containsAnyModels(in: modelContext)
            let hasExistingMedia = try environment.hasStoredMedia()
            let hasExistingOwner = try environment.localDataOwner() != nil
            guard !hasExistingSwiftData, !hasExistingMedia, !hasExistingOwner else {
                throw LocalAlphaDataResetError.ambiguousExistingData
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
        try deleteAll(CalendarEvent.self, from: modelContext)
        try deleteAll(SyncQueueItem.self, from: modelContext)
        try deleteAll(LocalCaptureMarker.self, from: modelContext)
        try deleteAll(LocalMarker.self, from: modelContext)
        try deleteAll(LocalFeedback.self, from: modelContext)
        try deleteAll(LocalArtifact.self, from: modelContext)
        try deleteAll(LocalPracticeEntry.self, from: modelContext)
        try deleteAll(LocalCourse.self, from: modelContext)
        try modelContext.save()

        guard try containsNoModels(in: modelContext) else {
            throw LocalAlphaDataResetError.swiftDataModelsStillExist
        }
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, from modelContext: ModelContext) throws {
        for model in try modelContext.fetch(FetchDescriptor<T>()) {
            modelContext.delete(model)
        }
    }

    private static func containsNoModels(in modelContext: ModelContext) throws -> Bool {
        try modelContext.fetch(FetchDescriptor<CalendarEvent>()).isEmpty &&
            modelContext.fetch(FetchDescriptor<SyncQueueItem>()).isEmpty &&
            modelContext.fetch(FetchDescriptor<LocalCaptureMarker>()).isEmpty &&
            modelContext.fetch(FetchDescriptor<LocalMarker>()).isEmpty &&
            modelContext.fetch(FetchDescriptor<LocalFeedback>()).isEmpty &&
            modelContext.fetch(FetchDescriptor<LocalArtifact>()).isEmpty &&
            modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty &&
            modelContext.fetch(FetchDescriptor<LocalCourse>()).isEmpty
    }

    private static func containsAnyModels(in modelContext: ModelContext) throws -> Bool {
        try !containsNoModels(in: modelContext)
    }
}

enum LocalAlphaDataResetError: LocalizedError, Equatable {
    case ambiguousExistingData
    case swiftDataModelsStillExist
    case mediaStillExists
    case localDataOwnerStillExists
    case generationWriteVerificationFailed

    var errorDescription: String? {
        switch self {
        case .ambiguousExistingData:
            return "Existing local data needs recovery before this alpha reset can continue."
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
