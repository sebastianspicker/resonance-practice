import Foundation
import SwiftData

// Removes only fixture-owned rows and associated local media from the demo domain.
@MainActor
struct DemoDataCleanup {
    let modelContext: ModelContext
    let demoPrefix: String

    func clear() throws {
        let courses = try modelContext.fetch(FetchDescriptor<LocalCourse>())
        let entries = try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>())
        let artifacts = try modelContext.fetch(FetchDescriptor<LocalArtifact>())
        let feedback = try modelContext.fetch(FetchDescriptor<LocalFeedback>())
        let markers = try modelContext.fetch(FetchDescriptor<LocalMarker>())
        let captureMarkers = try modelContext.fetch(FetchDescriptor<LocalCaptureMarker>())
        let queueItems = try modelContext.fetch(FetchDescriptor<SyncQueueItem>())

        let demoCourses = courses.filter { $0.id.hasPrefix(demoPrefix) }
        let demoEntries = entries.filter { $0.id.hasPrefix(demoPrefix) || $0.courseId.hasPrefix(demoPrefix) }
        let demoEntryIDs = Set(demoEntries.map(\.id))
        let demoArtifacts = artifacts.filter {
            $0.id.hasPrefix(demoPrefix) || $0.entryId.hasPrefix(demoPrefix) || demoEntryIDs.contains($0.entryId)
        }
        let demoArtifactIDs = Set(demoArtifacts.map(\.id))
        let demoFeedback = feedback.filter {
            $0.id.hasPrefix(demoPrefix) ||
                $0.targetId.hasPrefix(demoPrefix) ||
                demoEntryIDs.contains($0.targetId) ||
                demoArtifactIDs.contains($0.targetId)
        }
        let demoCaptureMarkers = captureMarkers.filter {
            $0.id.hasPrefix(demoPrefix) || demoEntryIDs.contains($0.entryId) || demoArtifactIDs.contains($0.artifactId)
        }
        let demoQueueItems = queueItems.filter { isDemoQueueItem($0) }

        // Artifact rows do not delete their files automatically. Remove media
        // before SwiftData records so demo cleanup leaves no local evidence.
        for artifact in demoArtifacts where !artifact.localPath.isEmpty {
            FileStore.deleteFileIfExists(atPath: artifact.localPath)
        }

        demoCourses.forEach(modelContext.delete)
        demoEntries.forEach(modelContext.delete)
        demoArtifacts.forEach(modelContext.delete)
        demoFeedback.forEach(modelContext.delete)
        markers.filter { $0.id.hasPrefix(demoPrefix) }.forEach(modelContext.delete)
        demoCaptureMarkers.forEach(modelContext.delete)
        demoQueueItems.forEach(modelContext.delete)

        try modelContext.save()
    }

    private func isDemoQueueItem(_ item: SyncQueueItem) -> Bool {
        guard let data = item.payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return item.id.hasPrefix(demoPrefix)
        }
        let referencedIDs = ["entryId", "artifactId", "feedbackId", "targetId"]
        return item.id.hasPrefix(demoPrefix) || referencedIDs.contains {
            (payload[$0] as? String)?.hasPrefix(demoPrefix) == true
        }
    }
}
