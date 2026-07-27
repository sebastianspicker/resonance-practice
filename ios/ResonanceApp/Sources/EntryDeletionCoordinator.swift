import Foundation
import SwiftData

// Translates entry deletion into consistent local cleanup and, when needed, durable remote work.

/// Reports whether deletion left durable server work after local cleanup completed.
struct EntryDeletionResult {
    let enqueuedRemoteDelete: Bool
}

/// Failures that stop deletion before local records are partially removed.
enum EntryDeletionError: LocalizedError {
    case invalidDeletePayload
    case missingOwner

    var errorDescription: String? {
        switch self {
        case .invalidDeletePayload:
            return "Unable to create the remote deletion request."
        case .missingOwner:
            return "Sign in again before deleting an entry that exists on the server."
        }
    }
}

@MainActor
enum EntryDeletionCoordinator {
    /// Delete a local entry without leaving orphaned queue work behind.
    ///
    /// Pending work for the entry is cancelled. Entries with an authoritative
    /// server version are replaced by one durable remote delete intent; entries
    /// that have never synced are removed locally without sending an invalid
    /// version-zero command.
    ///
    /// Local audio files are removed immediately because the queue no longer has
    /// any valid task that can upload them after the parent entry is gone.
    static func delete(
        entry: LocalPracticeEntry,
        modelContext: ModelContext,
        ownerId: String?,
        additionalOwnedMediaPaths: [String] = [],
        removeArtifactFile: (String) throws -> Void = FileStore.removeFileIfExists
    ) throws -> EntryDeletionResult {
        let entryId = entry.id
        let artifactIds = Set(entry.artifacts.map(\.id))
        let queueItems = try modelContext.fetch(FetchDescriptor<SyncQueueItem>())
        // Preserve the version at deletion time because the local entry is
        // removed before its durable command is processed.
        let remoteDelete = try entry.serverVersion.map { baseVersion in
            guard let ownerId, !ownerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EntryDeletionError.missingOwner
            }
            return try makeRemoteDeleteIntent(entryId: entryId, baseVersion: baseVersion, ownerId: ownerId)
        }

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

        if let remoteDelete {
            modelContext.insert(remoteDelete)
        }
        modelContext.delete(entry)
        try modelContext.save()

        return EntryDeletionResult(enqueuedRemoteDelete: remoteDelete != nil)
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

    private static func makeRemoteDeleteIntent(
        entryId: String,
        baseVersion: Int,
        ownerId: String
    ) throws -> SyncQueueItem {
        let payload: [String: Any] = ["entryId": entryId, "baseVersion": baseVersion]
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
            payloadJSON: payloadJSON,
            ownerId: ownerId
        )
    }
}
