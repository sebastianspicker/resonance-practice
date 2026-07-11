import Foundation
import os
import SwiftData

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "Persistence")

@MainActor
enum PersistenceController {
    static let shared: Result<ModelContainer, Error> = createPersistentContainer()

    static func createContainer(inMemory: Bool = false) -> ModelContainer {
        do {
            return try makeContainer(inMemory: inMemory)
        } catch {
            logger.fault("Failed to create ModelContainer: \(error.localizedDescription)")
            fatalError("Unable to create ModelContainer: \(error)")
        }
    }

    private static func createPersistentContainer() -> Result<ModelContainer, Error> {
        do {
            return .success(try makeContainer(inMemory: false))
        } catch {
            logger.fault("Failed to create persistent ModelContainer: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    private static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema([
            LocalCourse.self,
            LocalPracticeEntry.self,
            LocalArtifact.self,
            LocalFeedback.self,
            LocalMarker.self,
            LocalCaptureMarker.self,
            SyncQueueItem.self,
            CalendarEvent.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
