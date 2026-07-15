import Foundation
import SwiftData

struct EntryDeletionResult {
    let enqueuedRemoteDelete: Bool
}

enum EntryDeletionError: LocalizedError {
    case invalidDeletePayload

    var errorDescription: String? {
        switch self {
        case .invalidDeletePayload:
            return "Unable to create the remote deletion request."
        }
    }
}

@MainActor
enum EntryDeletionCoordinator {
    /// Delete a local entry without leaving orphaned queue work behind.
    ///
    /// Pending work for the entry is cancelled and replaced by one durable remote
    /// delete intent. DELETE is idempotent at the API boundary, so this remains
    /// correct even when a local create may already have reached the server.
    ///
    /// Local audio files are removed immediately because the queue no longer has
    /// any valid task that can upload them after the parent entry is gone.
    static func delete(
        entry: LocalPracticeEntry,
        modelContext: ModelContext,
        additionalOwnedMediaPaths: [String] = [],
        removeArtifactFile: (String) throws -> Void = FileStore.removeFileIfExists
    ) throws -> EntryDeletionResult {
        let entryId = entry.id
        let artifactIds = Set(entry.artifacts.map(\.id))
        let queueItems = try modelContext.fetch(FetchDescriptor<SyncQueueItem>())
        let remoteDelete = try makeRemoteDeleteIntent(entryId: entryId)

        // This is deliberately before every SwiftData mutation. A verified
        // filesystem failure leaves local records and queued work intact.
        var encounteredPaths = Set<String>()
        let mediaPaths = entry.artifacts.map(\.localPath) + additionalOwnedMediaPaths
        for path in mediaPaths where !path.isEmpty && encounteredPaths.insert(path).inserted {
            try removeArtifactFile(path)
        }

        for item in queueItems {
            guard referencesDeletedData(item, entryId: entryId, artifactIds: artifactIds) else {
                continue
            }
            modelContext.delete(item)
        }

        modelContext.insert(remoteDelete)
        modelContext.delete(entry)
        try modelContext.save()

        return EntryDeletionResult(enqueuedRemoteDelete: true)
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

    private static func makeRemoteDeleteIntent(entryId: String) throws -> SyncQueueItem {
        let payload = ["entryId": entryId]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw EntryDeletionError.invalidDeletePayload
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw EntryDeletionError.invalidDeletePayload
        }
        return SyncQueueItem(
            id: UUID().uuidString,
            type: SyncTaskType.deleteEntry.rawValue,
            payloadJSON: payloadJSON
        )
    }
}
