import Foundation
import os
import SwiftData

// Encapsulates SwiftData queue reads, ownership filtering, retries, and cleanup mutations.

/// Owns all SwiftData read/write operations for the sync queue, local entries,
/// and local artifacts.
///
/// `SyncManager` delegates every model-context interaction here so that queue
/// access has one persistence boundary and can be tested in isolation.
@MainActor
final class QueueStore {
    static let maxReadyWindow = 50
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "resonance",
        category: "QueueStore"
    )
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        // A processing status is only valid while its owning process is alive.
        // Recover persisted work before any sync pass can select queue items.
        resetStuckProcessing()
    }

    // MARK: - Enqueueing

    /// Serializes a versioned payload and appends a new `SyncQueueItem`.
    @discardableResult
    func enqueue(type: SyncTaskType, payload: OutboxPayload, ownerId: String) -> Bool {
        guard !ownerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Self.logger.error("Refusing to enqueue sync work without a verified owner")
            return false
        }
        guard payload.isCompatible(with: type) else {
            Self.logger.error("Refusing incompatible sync payload for \(type.rawValue)")
            return false
        }
        let json: String
        do {
            json = try OutboxEnvelope(taskType: type, payload: payload).encodedJSON()
        } catch {
            Self.logger.error("Failed to serialize sync payload for \(type.rawValue): \(error.localizedDescription)")
            return false
        }
        if let identity = taskIdentity(for: payload),
           let existing = existingTask(type: type, identity: identity, ownerId: ownerId) {
            existing.payloadJSON = json
            existing.status = SyncStatus.pending.rawValue
            existing.retryCount = 0
            existing.lastError = nil
            existing.nextAttemptAt = nil
            save()
            return true
        }
        let item = SyncQueueItem(
            id: UUID().uuidString,
            type: type.rawValue,
            payloadJSON: json,
            ownerId: ownerId
        )
        modelContext.insert(item)
        save()
        return true
    }

    // MARK: - Fetching

    /// Return all pending items whose `nextAttemptAt` is in the past (or unset),
    /// sorted oldest-first (FIFO).
    func fetchReady(now: Date, ownerId: String, limit: Int = maxReadyWindow) throws -> [SyncQueueItem] {
        guard !ownerId.isEmpty, limit > 0 else { return [] }
        let pendingValue = SyncStatus.pending.rawValue
        let requestedLimit = min(limit, Self.maxReadyWindow)
        var ready: [SyncQueueItem] = []
        var cursor: (createdAt: Date, id: String)?

        // The in-memory SwiftData store does not translate optional-date
        // comparisons. Scan owner/status rows in keyset windows, applying retry
        // readiness locally, so future rows cannot hide later ready work and no
        // unbounded result set reaches the main actor.
        while ready.count < requestedLimit {
            let batch = try pendingBatch(
                ownerId: ownerId,
                pendingValue: pendingValue,
                after: cursor
            )
            guard !batch.isEmpty else { break }
            for item in batch where item.nextAttemptAt == nil || (item.nextAttemptAt ?? now) <= now {
                ready.append(item)
                if ready.count == requestedLimit { break }
            }
            guard let last = batch.last else { break }
            cursor = (last.createdAt, last.id)
        }
        return ready
    }

    /// Return counts for the published queue metrics.
    func counts(ownerId: String?) -> (pending: Int, failed: Int) {
        guard let ownerId, !ownerId.isEmpty else { return (0, 0) }
        let pendingValue = SyncStatus.pending.rawValue
        let processingValue = SyncStatus.processing.rawValue
        let failedValue = SyncStatus.failed.rawValue
        let pendingDescriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate {
                $0.ownerId == ownerId &&
                    ($0.status == pendingValue || $0.status == processingValue)
            }
        )
        let failedDescriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.ownerId == ownerId && $0.status == failedValue }
        )
        do {
            let pendingCount = try modelContext.fetchCount(pendingDescriptor)
            let failedCount = try modelContext.fetchCount(failedDescriptor)
            return (pendingCount, failedCount)
        } catch {
            Self.logger.error("Failed to count queue items: \(error.localizedDescription)")
            return (0, 0)
        }
    }

    // MARK: - Status mutations

    /// Reset all `failed` items back to `pending` so they will be retried.
    func resetAllFailed(ownerId: String) {
        guard !ownerId.isEmpty else { return }
        let failedValue = SyncStatus.failed.rawValue
        let descriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate { $0.ownerId == ownerId && $0.status == failedValue }
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
    /// Called at store initialization and from the background-task expiration handler.
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

    /// Permanently removes queued work for an entry after deletion or authoritative reconciliation.
    func discardWork(forEntryID entryID: String) {
        let descriptor = FetchDescriptor<SyncQueueItem>()
        guard let items = try? modelContext.fetch(descriptor) else { return }
        for item in items where decodedPayload(for: item)?.entryID == entryID {
            modelContext.delete(item)
        }
        save()
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
        guard let artifactId = decodedPayload(for: item)?.artifactID,
              let artifact = try? fetchArtifact(id: artifactId) else { return }
        artifact.uploadState = .failed
        artifact.syncPhase = .failed
        save()
    }

    /// Reset the artifact referenced by `item`'s payload to a retryable state.
    func resetArtifactStateForRetryIfNeeded(item: SyncQueueItem) {
        guard isArtifactTask(item) else { return }
        guard let artifactId = decodedPayload(for: item)?.artifactID,
              let artifact = try? fetchArtifact(id: artifactId) else { return }
        artifact.uploadState = .pending
        artifact.syncPhase = .queued
        save()
    }

    // MARK: - Private helpers

    private func isArtifactTask(_ item: SyncQueueItem) -> Bool {
        item.type == SyncTaskType.syncArtifact.rawValue
    }

    private func pendingBatch(
        ownerId: String,
        pendingValue: String,
        after cursor: (createdAt: Date, id: String)?
    ) throws -> [SyncQueueItem] {
        var descriptor: FetchDescriptor<SyncQueueItem>
        if let cursor {
            let afterDate = cursor.createdAt
            let afterID = cursor.id
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.status == pendingValue && $0.ownerId == ownerId &&
                        ($0.createdAt > afterDate ||
                            ($0.createdAt == afterDate && $0.id > afterID))
                }
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.status == pendingValue && $0.ownerId == ownerId }
            )
        }
        descriptor.sortBy = [
            SortDescriptor(\.createdAt, order: .forward),
            SortDescriptor(\.id, order: .forward)
        ]
        descriptor.fetchLimit = Self.maxReadyWindow
        return try modelContext.fetch(descriptor)
    }

    private func taskIdentity(for payload: OutboxPayload) -> String? {
        payload.artifactID ?? payload.entryID ?? payload.feedbackID
    }

    private func existingTask(type: SyncTaskType, identity: String, ownerId: String) -> SyncQueueItem? {
        let typeValue = type.rawValue
        let processingValue = SyncStatus.processing.rawValue
        let descriptor = FetchDescriptor<SyncQueueItem>(
            predicate: #Predicate {
                $0.type == typeValue && $0.ownerId == ownerId && $0.status != processingValue
            }
        )
        return try? modelContext.fetch(descriptor).first { item in
            guard let payload = decodedPayload(for: item)
            else { return false }
            return taskIdentity(for: payload) == identity
        }
    }

    /// Decodes older object-shaped rows once and upgrades their persisted form.
    private func decodedPayload(for item: SyncQueueItem) -> OutboxPayload? {
        guard let taskType = item.taskType,
              let decoded = try? OutboxEnvelope.decode(payloadJSON: item.payloadJSON, taskType: taskType)
        else { return nil }
        if decoded.migrated, let encoded = try? decoded.envelope.encodedJSON() {
            item.payloadJSON = encoded
        }
        return decoded.envelope.payload
    }
}
