import Foundation
import os
import SwiftData
import UIKit

// Coordinates authenticated, owner-scoped synchronization and its durable local queue.

/// Sync queue item status values. Raw string values are used for SwiftData compatibility.
enum SyncStatus: String, Codable, Sendable {
    case pending
    case processing
    case failed
}

enum SyncTaskType: String, Codable, Sendable {
    case createEntry
    case updateEntry
    case submitEntry
    case deleteEntry
    case postFeedback
    case syncArtifact
    case syncCaptureProfile
    case syncCaptureMarkers
}

/// Errors that can occur during sync operations
enum SyncError: LocalizedError {
    case payloadParseError(String)
    case unknownTaskType(String)
    case localFileNotFound(String)
    case invalidPresignUrl(String)
    case localFileMetadataUnavailable(String)
    case localFeedbackNotFound(String)
    case localCaptureMarkersNotFound(String)
    case dependenciesPending(String)
    case invalidCommandBatchSize(Int)
    case serverConflict(entityId: String, currentVersion: Int?)
    case commandRejected(String)
    case commandRetryable(String)
    case missingServerVersion(String)

    var errorDescription: String? {
        switch self {
        case .payloadParseError(let message): return message
        case .unknownTaskType(let message): return message
        case .localFileNotFound(let message): return message
        case .invalidPresignUrl(let message): return message
        case .localFileMetadataUnavailable(let message): return message
        case .localFeedbackNotFound(let message): return message
        case .localCaptureMarkersNotFound(let message): return message
        case .dependenciesPending(let message): return message
        case .invalidCommandBatchSize(let count): return "Sync batches must contain between 1 and 25 commands, got \(count)."
        case let .serverConflict(entityId, currentVersion):
            if let currentVersion {
                return "The server has a newer copy of entry \(entityId) (version \(currentVersion))."
            }
            return "The server has a newer copy of entry \(entityId)."
        case .commandRejected(let message): return message
        case .commandRetryable(let message): return message
        case .missingServerVersion(let entryID): return "Entry \(entryID) must be refreshed before it can be changed."
        }
    }
}

/// Thin coordinator that drives the sync queue.
///
/// Responsibilities:
/// - Auth refresh gating (via `AuthManager`)
/// - Network reachability check (via `NetworkMonitor`)
/// - Queue state machine: fetching ready items, updating status, applying retry
///
/// All SwiftData I/O is delegated to `QueueStore`.
/// All retry decisions are delegated to `RetryPolicy`.
/// All API calls are delegated to `TaskExecutor`.
@MainActor
/// Owns queue-pass lifecycle and invalidates stale work across profile transitions.
final class SyncManager: ObservableObject {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "SyncManager")
    let apiClient: APIClient
    let authManager: AuthManager
    let networkMonitor: NetworkMonitor
    let store: QueueStore
    let retryPolicy: RetryPolicy
    let taskExecutor: TaskExecutor
    let processItemOverride: (@MainActor (SyncQueueItem, String) async throws -> Void)?
    let verifiedOwner: () throws -> String?
    private var isProcessingQueue = false
    var needsAnotherQueuePass = false
    private var activeProcessingTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskGeneration: UUID?
    var processingGeneration = 0

    @Published var lastSyncedAt: Date?
    @Published var pendingQueueCount: Int = 0
    @Published var failedQueueCount: Int = 0
    @Published var conflictedEntryIDs: Set<String> = []

    init(
        modelContext: ModelContext,
        authManager: AuthManager,
        apiClient: APIClient,
        networkMonitor: NetworkMonitor? = nil,
        verifiedOwner: @escaping () throws -> String? = {
            try KeychainStore.read("localDataOwnerId")
        },
        taskSession: URLSession? = nil,
        processItemOverride: (@MainActor (SyncQueueItem, String) async throws -> Void)? = nil
    ) {
        self.authManager = authManager
        self.apiClient = apiClient
        self.networkMonitor = networkMonitor ?? NetworkMonitor()
        self.processItemOverride = processItemOverride
        self.verifiedOwner = verifiedOwner
        self.store = QueueStore(modelContext: modelContext)
        self.retryPolicy = RetryPolicy()
        // Use a standard (non-background) session configuration. Background
        // URLSession does NOT support the async upload(for:fromFile:) API and
        // would throw at runtime. Extended execution time is already handled
        // by UIApplication.beginBackgroundTask in processQueue().
        let session = taskSession ?? Self.makeTaskSession()
        self.taskExecutor = TaskExecutor(apiClient: apiClient, store: self.store, session: session)
        updateQueueMetrics()
    }

    private static func makeTaskSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    /// Enqueue a sync task for later processing.
    ///
    /// - Important: If the payload cannot be serialized to JSON, the item is
    ///   **not** silently dropped. An error is logged so developers can diagnose
    ///   the issue (e.g., non-serializable values in the dictionary).
    func enqueue(type: SyncTaskType, payload: [String: Any]) {
        guard let ownerId = authorizedOwner() else {
            Self.logger.error("Refusing to enqueue sync work without a verified authenticated owner")
            updateQueueMetrics()
            return
        }
        store.enqueue(type: type, payload: payload, ownerId: ownerId)
        updateQueueMetrics()
    }

    func retryFailedItems() {
        guard let ownerId = authorizedOwner() else {
            updateQueueMetrics()
            return
        }
        store.resetAllFailed(ownerId: ownerId)
        updateQueueMetrics()
    }

    /// Invalidates any in-flight response before a profile/account transition.
    /// The next response check will leave the old account's local data untouched.
    /// Advances the generation so responses started for an old profile cannot mutate current data.
    func invalidateProcessing() {
        activeProcessingTask?.cancel()
        processingGeneration &+= 1
        store.resetStuckProcessing()
    }

    /// Cancels and joins in-flight work before destructive local-data changes.
    /// `TaskExecutor` cooperatively checks this cancellation around every
    /// artifact-session await, preventing a late response from recreating data.
    func cancelAndWaitForProcessing() async {
        invalidateProcessing()
        let task = activeProcessingTask
        task?.cancel()
        await task?.value
        store.resetStuckProcessing()
    }

    func reloadServerCopy(of entry: LocalPracticeEntry) async throws {
        guard let accessToken = authManager.session?.accessToken else { return }
        let response = try await apiClient.fetchEntry(accessToken: accessToken, entryId: entry.id)
        entry.kind = EntryKind(rawValue: response.kind ?? "") ?? entry.kind
        entry.practiceDate = response.practiceDate
        entry.goalText = response.goalText
        entry.durationSeconds = response.durationSeconds
        entry.tags = response.tags
        entry.notes = response.notes
        entry.status = EntryStatus(rawValue: response.status) ?? entry.status
        entry.consentConfirmedAt = response.consentConfirmedAt
        entry.consentScope = response.consentScope.flatMap(ConsentScope.init(rawValue:))
        entry.captureProfile = response.captureProfile.flatMap(CaptureProfile.init(rawValue:))
        entry.remoteUpdatedAt = response.updatedAt ?? response.createdAt ?? Date()
        entry.updatedAt = entry.remoteUpdatedAt ?? Date()
        entry.serverVersion = response.version
        store.discardWork(forEntryID: entry.id)
        conflictedEntryIDs.remove(entry.id)
        store.save()
        updateQueueMetrics()
    }

    @discardableResult
    func duplicateAsNewDraft(_ entry: LocalPracticeEntry, modelContext: ModelContext) throws -> LocalPracticeEntry {
        let copy = LocalPracticeEntry(
            id: UUID().uuidString,
            courseId: entry.courseId,
            studentId: entry.studentId,
            details: PracticeEntryDetails(
                practiceDate: entry.practiceDate,
                goalText: entry.goalText,
                durationSeconds: entry.durationSeconds,
                tags: entry.tags,
                notes: entry.notes
            ),
            status: .draft,
            captureContext: CaptureContext(
                kind: entry.kind,
                consentConfirmedAt: entry.consentConfirmedAt,
                consentScope: entry.consentScope,
                captureProfile: entry.captureProfile
            )
        )
        modelContext.insert(copy)
        try modelContext.save()
        enqueue(type: .createEntry, payload: ["entryId": copy.id])
        return copy
    }

    /// Serializes queue passes while recording a requested follow-up pass instead of overlapping work.
    func processQueue() async {
        if isProcessingQueue {
            needsAnotherQueuePass = true
            return
        }

        isProcessingQueue = true
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.runQueuePasses()
        }
        activeProcessingTask = task
        await task.value
        activeProcessingTask = nil
    }

    private func runQueuePasses() async {
        defer {
            isProcessingQueue = false
            needsAnotherQueuePass = false
        }
        repeat {
            guard !Task.isCancelled else { return }
            needsAnotherQueuePass = false
            await processQueuePass()
        } while needsAnotherQueuePass
    }

    private func processQueuePass() async {
        // Skip processing when the device has no network connectivity.
        // Items remain in the queue and will be processed on the next attempt.
        guard networkMonitor.isOnline else {
            Self.logger.info("Skipping sync queue processing: device is offline")
            return
        }

        guard let ownerId = authorizedOwner() else {
            updateQueueMetrics()
            return
        }
        let currentProcessingGeneration = processingGeneration
        let backgroundTaskGeneration = UUID()
        self.backgroundTaskGeneration = backgroundTaskGeneration
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ResonanceSync") {
            // Background time expired: reset any stuck "processing" items so they retry next launch.
            // Use DispatchQueue.main.async instead of Task { @MainActor } to avoid queueing
            // behind the current async sync operation, which could cause the expiration handler
            // to run too late (after the OS suspends the app).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.backgroundTaskGeneration == backgroundTaskGeneration else {
                    return
                }
                self.store.resetStuckProcessing()
                self.endBackgroundTask(generation: backgroundTaskGeneration)
            }
        }

        defer {
            endBackgroundTask(generation: backgroundTaskGeneration)
        }

        await authManager.refreshIfNeeded()
        guard isProcessingCurrent(currentProcessingGeneration, ownerId: ownerId),
              authManager.session?.accessToken != nil else { return }
        guard let items = fetchReadyItems(ownerId: ownerId) else { return }
        await process(items: items, ownerId: ownerId, processingGeneration: currentProcessingGeneration)
        guard isProcessingCurrent(currentProcessingGeneration, ownerId: ownerId) else { return }
        finishQueuePass(items)
    }

    private func endBackgroundTask(generation: UUID) {
        guard backgroundTaskGeneration == generation else { return }
        let taskID = backgroundTaskID
        backgroundTaskID = .invalid
        backgroundTaskGeneration = nil
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }

    private func fetchReadyItems(ownerId: String) -> [SyncQueueItem]? {
        do {
            return try store.fetchReady(now: Date(), ownerId: ownerId)
        } catch {
            Self.logger.error("Failed to fetch pending sync items: \(error.localizedDescription)")
            return nil
        }
    }

}
