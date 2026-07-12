import Foundation
import os
import SwiftData

/// Owns all SwiftData read/write operations for the sync queue, local entries,
/// and local artifacts.
///
/// `SyncManager` delegates every model-context interaction here so that queue
/// access has one persistence boundary and can be tested in isolation.
@MainActor
final class QueueStore {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "resonance",
        category: "QueueStore"
    )
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Enqueueing

    /// Serialize `payload` and append a new `SyncQueueItem` to the queue.
    ///
    /// If the payload cannot be serialised to JSON, the item is **not** silently
    /// dropped. An error is logged so developers can diagnose the issue.
    func enqueue(type: SyncTaskType, payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload) else {
            Self.logger.error("Failed to serialize sync payload for \(type.rawValue): payload is not valid JSON")
            return
        }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            Self.logger.error("Failed to serialize sync payload for \(type.rawValue): \(error.localizedDescription)")
            return
        }
        guard let json = String(data: data, encoding: .utf8) else {
            Self.logger.error("Failed to encode sync payload as UTF-8 for \(type.rawValue)")
            return
        }
        if let identity = taskIdentity(type: type, payload: payload),
           let existing = existingTask(type: type, identity: identity) {
            existing.payloadJSON = json
            existing.status = SyncStatus.pending.rawValue
            existing.retryCount = 0
            existing.lastError = nil
            existing.nextAttemptAt = nil
            save()
            return
        }
        let item = SyncQueueItem(id: UUID().uuidString, type: type.rawValue, payloadJSON: json)
        modelContext.insert(item)
        save()
    }

    // MARK: - Fetching

    /// Return all pending items whose `nextAttemptAt` is in the past (or unset),
    /// sorted oldest-first (FIFO).
    func fetchReady(now: Date) throws -> [SyncQueueItem] {
        let pendingValue = SyncStatus.pending.rawValue
        var descriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { item in item.status == pendingValue }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .forward)]
        return try modelContext.fetch(descriptor).filter {
            $0.nextAttemptAt == nil || ($0.nextAttemptAt ?? now) <= now
        }
    }

    /// Return all items currently in the `failed` state.
    func fetchFailed() throws -> [SyncQueueItem] {
        let failedValue = SyncStatus.failed.rawValue
        let descriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.status == failedValue }
        )
        return try modelContext.fetch(descriptor)
    }

    /// Return counts for the published queue metrics.
    func counts() -> (pending: Int, failed: Int) {
        let pendingValue = SyncStatus.pending.rawValue
        let processingValue = SyncStatus.processing.rawValue
        let failedValue = SyncStatus.failed.rawValue
        let pendingDescriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.status == pendingValue || $0.status == processingValue }
        )
        let failedDescriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.status == failedValue }
        )
        do {
            let p = try modelContext.fetch(pendingDescriptor).count
            let f = try modelContext.fetch(failedDescriptor).count
            return (p, f)
        } catch {
            Self.logger.error("Failed to count queue items: \(error.localizedDescription)")
            return (0, 0)
        }
    }

    // MARK: - Status mutations

    /// Reset all `failed` items back to `pending` so they will be retried.
    func resetAllFailed() {
        let failedValue = SyncStatus.failed.rawValue
        let descriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.status == failedValue }
        )
        let failedItems: [SyncQueueItem]
        do {
            failedItems = try modelContext.fetch(descriptor)
        } catch {
            Self.logger.error("Failed to fetch failed sync items for retry: \(error.localizedDescription)")
            return
        }
        for item in failedItems {
            item.status = SyncStatus.pending.rawValue
            item.nextAttemptAt = nil
            item.lastError = nil
            resetArtifactStateForRetryIfNeeded(item: item)
        }
        save()
    }

    /// Reset any items currently stuck in `processing` back to `pending`.
    ///
    /// Called from the UIApplication background-task expiration handler.
    func resetStuckProcessing() {
        let processingValue = SyncStatus.processing.rawValue
        let descriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.status == processingValue }
        )
        do {
            let stuck = try modelContext.fetch(descriptor)
            for item in stuck {
                item.status = SyncStatus.pending.rawValue
                item.nextAttemptAt = nil
            }
            if !stuck.isEmpty { save() }
        } catch {
            Self.logger.error("Failed to fetch stuck sync items on background expiry: \(error.localizedDescription)")
        }
    }

    func delete(_ item: SyncQueueItem) {
        modelContext.delete(item)
    }

    func save() {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Failed to save model context: \(error.localizedDescription)")
        }
    }

    // MARK: - Model lookups

    func fetchFirst<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> T {
        guard let first = try modelContext.fetch(descriptor).first else {
            throw NSError(domain: "SyncLocal", code: 404, userInfo: [NSLocalizedDescriptionKey: "Item not found in local DB"])
        }
        return first
    }

    func fetchEntry(id: String) throws -> LocalPracticeEntry {
        try fetchFirst(FetchDescriptor<LocalPracticeEntry>(predicate: #Predicate { $0.id == id }))
    }

    func fetchArtifact(id: String) throws -> LocalArtifact {
        try fetchFirst(FetchDescriptor<LocalArtifact>(predicate: #Predicate { $0.id == id }))
    }

    func fetchCaptureMarkers(entryId: String) throws -> [LocalCaptureMarker] {
        var descriptor = FetchDescriptor<LocalCaptureMarker>(
            predicate: #Predicate { $0.entryId == entryId }
        )
        descriptor.sortBy = [SortDescriptor(\.timeSeconds, order: .forward)]
        return try modelContext.fetch(descriptor)
    }

    // MARK: - Artifact state helpers

    /// Mark the artifact referenced by `item`'s payload as permanently failed.
    func updateArtifactFailureIfNeeded(item: SyncQueueItem) {
        guard isArtifactTask(item) else { return }
        guard let artifactId = artifactId(from: item),
              let artifact = try? fetchArtifact(id: artifactId) else { return }
        artifact.uploadState = .failed
        artifact.syncPhase = .failed
        save()
    }

    /// Reset the artifact referenced by `item`'s payload to a retryable state.
    func resetArtifactStateForRetryIfNeeded(item: SyncQueueItem) {
        guard isArtifactTask(item) else { return }
        guard let artifactId = artifactId(from: item),
              let artifact = try? fetchArtifact(id: artifactId) else { return }
        artifact.uploadState = .pending
        artifact.syncPhase = .queued
        save()
    }

    // MARK: - Private helpers

    private func isArtifactTask(_ item: SyncQueueItem) -> Bool {
        item.type == SyncTaskType.syncArtifact.rawValue
    }

    private func artifactId(from item: SyncQueueItem) -> String? {
        guard let data = item.payloadJSON.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return payload["artifactId"] as? String
    }

    private func taskIdentity(type: SyncTaskType, payload: [String: Any]) -> String? {
        switch type {
        case .syncArtifact:
            return payload["artifactId"] as? String
        case .createEntry, .updateEntry, .submitEntry, .deleteEntry, .syncCaptureProfile, .syncCaptureMarkers:
            return payload["entryId"] as? String
        case .postFeedback:
            return payload["feedbackId"] as? String
        }
    }

    private func existingTask(type: SyncTaskType, identity: String) -> SyncQueueItem? {
        let typeValue = type.rawValue
        let descriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.type == typeValue }
        )
        return try? modelContext.fetch(descriptor).first { item in
            guard item.status != SyncStatus.processing.rawValue,
                  let data = item.payloadJSON.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return taskIdentity(type: type, payload: payload) == identity
        }
    }
}
