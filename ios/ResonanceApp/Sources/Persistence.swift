import Foundation
import os
import SwiftData

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "Persistence")

@MainActor
enum PersistenceController {
    static let shared = createContainer()

    static func createContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema([
            LocalCourse.self,
            LocalPracticeEntry.self,
            LocalArtifact.self,
            LocalFeedback.self,
            LocalMarker.self,
            SyncQueueItem.self,
            CalendarEvent.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            logger.error("Failed to create ModelContainer: \(error.localizedDescription). Falling back to an in-memory store without modifying on-disk data.")
#if DEBUG
            assertionFailure("Persistent store initialization failed; the app is running with an in-memory fallback store.")
#endif

            let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [memoryConfig])
            } catch {
                // If even an in-memory container fails, the schema itself is broken.
                // This is a programmer error that cannot be recovered at runtime.
                fatalError("Unable to create even an in-memory ModelContainer: \(error)")
            }
        }
    }
}
