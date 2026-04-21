import Foundation
import SwiftData

struct EntryDeletionResult {
    let enqueuedRemoteDelete: Bool
}

@MainActor
enum EntryDeletionCoordinator {
    static func delete(
        entry: LocalPracticeEntry,
        modelContext: ModelContext,
        enqueue: (SyncTaskType, [String: Any]) -> Void
    ) throws -> EntryDeletionResult {
        let entryId = entry.id
        let artifactIds = Set(entry.artifacts.map(\.id))
        let queueItems = try modelContext.fetch(FetchDescriptor<SyncQueueItem>())

        let hasPendingCreate = queueItems.contains {
            $0.type == SyncTaskType.createEntry.rawValue && referencesDeletedData($0, entryId: entryId, artifactIds: artifactIds)
        }
        let hasPendingDelete = queueItems.contains {
            $0.type == SyncTaskType.deleteEntry.rawValue && referencesDeletedData($0, entryId: entryId, artifactIds: artifactIds)
        }

        for item in queueItems {
            guard referencesDeletedData(item, entryId: entryId, artifactIds: artifactIds) else {
                continue
            }

            if item.type == SyncTaskType.deleteEntry.rawValue && hasPendingCreate == false {
                continue
            }

            modelContext.delete(item)
        }

        for artifact in entry.artifacts {
            FileStore.deleteFileIfExists(atPath: artifact.localPath)
        }

        let shouldEnqueueRemoteDelete = hasPendingCreate == false && hasPendingDelete == false
        if shouldEnqueueRemoteDelete {
            enqueue(.deleteEntry, ["entryId": entryId])
        }

        modelContext.delete(entry)
        try modelContext.save()

        return EntryDeletionResult(enqueuedRemoteDelete: shouldEnqueueRemoteDelete)
    }

    private static func referencesDeletedData(
        _ item: SyncQueueItem,
        entryId: String,
        artifactIds: Set<String>
    ) -> Bool {
        guard let data = item.payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        if (payload["entryId"] as? String) == entryId {
            return true
        }

        if let artifactId = payload["artifactId"] as? String, artifactIds.contains(artifactId) {
            return true
        }

        if item.type == SyncTaskType.postFeedback.rawValue,
           let targetId = payload["targetId"] as? String,
           targetId == entryId || artifactIds.contains(targetId) {
            return true
        }

        return false
    }
}
