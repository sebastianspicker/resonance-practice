import Foundation
import os
import SwiftData
import UIKit

/// Sync queue item status values. Raw string values are used for SwiftData compatibility.
enum SyncStatus: String {
    case pending = "pending"
    case processing = "processing"
    case failed = "failed"
}

enum SyncTaskType: String {
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
    case localFeedbackNotFound(String)
    case localCaptureMarkersNotFound(String)
    case dependenciesPending(String)

    var errorDescription: String? {
        switch self {
        case .payloadParseError(let message): return message
        case .unknownTaskType(let message): return message
        case .localFileNotFound(let message): return message
        case .invalidPresignUrl(let message): return message
        case .localFeedbackNotFound(let message): return message
        case .localCaptureMarkersNotFound(let message): return message
        case .dependenciesPending(let message): return message
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
final class SyncManager: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "SyncManager")
    private let apiClient: APIClient
    private let authManager: AuthManager
    private let networkMonitor: NetworkMonitor
    private let store: QueueStore
    private let retryPolicy: RetryPolicy
    private let taskExecutor: TaskExecutor
    private let processItemOverride: ((SyncQueueItem, String) async throws -> Void)?
    private var isProcessingQueue = false
    private var needsAnotherQueuePass = false

    @Published var lastSyncedAt: Date?
    @Published var pendingQueueCount: Int = 0
    @Published var failedQueueCount: Int = 0

    init(
        modelContext: ModelContext,
        authManager: AuthManager,
        apiClient: APIClient,
        networkMonitor: NetworkMonitor? = nil,
        processItemOverride: ((SyncQueueItem, String) async throws -> Void)? = nil
    ) {
        self.authManager = authManager
        self.apiClient = apiClient
        self.networkMonitor = networkMonitor ?? NetworkMonitor()
        self.processItemOverride = processItemOverride
        self.store = QueueStore(modelContext: modelContext)
        self.retryPolicy = RetryPolicy()
        // Use a standard (non-background) session configuration. Background
        // URLSession does NOT support the async upload(for:fromFile:) API and
        // would throw at runtime. Extended execution time is already handled
        // by UIApplication.beginBackgroundTask in processQueue().
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        self.taskExecutor = TaskExecutor(apiClient: apiClient, store: self.store, session: session)
        updateQueueMetrics()
    }

    /// Enqueue a sync task for later processing.
    ///
    /// - Important: If the payload cannot be serialized to JSON, the item is
    ///   **not** silently dropped. An error is logged so developers can diagnose
    ///   the issue (e.g., non-serializable values in the dictionary).
    func enqueue(type: SyncTaskType, payload: [String: Any]) {
        store.enqueue(type: type, payload: payload)
        updateQueueMetrics()
    }

    func retryFailedItems() {
        store.resetAllFailed()
        updateQueueMetrics()
    }

    func processQueue() async {
        if isProcessingQueue {
            needsAnotherQueuePass = true
            return
        }

        isProcessingQueue = true
        defer {
            isProcessingQueue = false
            needsAnotherQueuePass = false
        }

        repeat {
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

        let taskId = UIApplication.shared.beginBackgroundTask(withName: "ResonanceSync") {
            // Background time expired: reset any stuck "processing" items so they retry next launch.
            // Use DispatchQueue.main.async instead of Task { @MainActor } to avoid queueing
            // behind the current async sync operation, which could cause the expiration handler
            // to run too late (after the OS suspends the app).
            DispatchQueue.main.async { [weak self] in
                self?.store.resetStuckProcessing()
            }
        }

        defer {
            UIApplication.shared.endBackgroundTask(taskId)
        }

        await authManager.refreshIfNeeded()
        guard authManager.session?.accessToken != nil else { return }
        guard let items = fetchReadyItems() else { return }
        await process(items: items)
        finishQueuePass(items)
    }

    private func fetchReadyItems() -> [SyncQueueItem]? {
        do {
            return try store.fetchReady(now: Date())
        } catch {
            Self.logger.error("Failed to fetch pending sync items: \(error.localizedDescription)")
            return nil
        }
    }

    private func process(items: [SyncQueueItem]) async {
        for item in items {
            do {
                // Refresh the access token before each item so that a token
                // expiring mid-batch does not cause all remaining items to fail.
                await authManager.refreshIfNeeded()
                guard let accessToken = authManager.session?.accessToken else {
                    Self.logger.warning("Lost auth session mid-sync; aborting remaining items")
                    break
                }
                item.status = SyncStatus.processing.rawValue
                if let processItemOverride {
                    try await processItemOverride(item, accessToken)
                } else {
                    try await taskExecutor.execute(item: item, accessToken: accessToken)
                }
                store.delete(item)
            } catch {
                if case SyncError.dependenciesPending = error {
                    item.status = SyncStatus.pending.rawValue
                    item.lastError = nil
                    item.nextAttemptAt = Date().addingTimeInterval(2)
                    continue
                }
                item.retryCount += 1
                item.lastError = String(describing: error)

                if item.retryCount >= retryPolicy.maxAttempts {
                    item.status = SyncStatus.failed.rawValue
                    store.updateArtifactFailureIfNeeded(item: item)
                } else if retryPolicy.isTerminal(error) {
                    item.status = SyncStatus.failed.rawValue
                    store.updateArtifactFailureIfNeeded(item: item)
                } else {
                    item.status = SyncStatus.pending.rawValue
                    item.nextAttemptAt = Date().addingTimeInterval(retryPolicy.backoffDelay(retryCount: item.retryCount))
                    store.resetArtifactStateForRetryIfNeeded(item: item)
                }
            }
        }
    }

    private func finishQueuePass(_ items: [SyncQueueItem]) {
        if !items.isEmpty {
            lastSyncedAt = Date()
        }
        store.save()
        updateQueueMetrics()
    }

    private func updateQueueMetrics() {
        let (pending, failed) = store.counts()
        pendingQueueCount = pending
        failedQueueCount = failed
    }
}
