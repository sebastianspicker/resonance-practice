import Foundation
import os
import SwiftData
import UIKit

// Owns shared synchronization state and dependency wiring.

@MainActor
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

    var isProcessingQueue = false
    var needsAnotherQueuePass = false
    var activeProcessingTask: Task<Void, Never>?
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    var backgroundTaskGeneration: UUID?
    var processingGeneration = 0

    @Published var lastSyncedAt: Date?
    @Published var pendingQueueCount: Int = 0
    @Published var failedQueueCount: Int = 0
    @Published var conflictedEntryIDs: Set<String> = []

    init(
        composition: SyncManagerComposition,
        verifiedOwner: @escaping () throws -> String?,
        processItemOverride: (@MainActor (SyncQueueItem, String) async throws -> Void)?
    ) {
        self.authManager = composition.authManager
        self.apiClient = composition.apiClient
        self.networkMonitor = composition.networkMonitor
        self.store = composition.store
        self.retryPolicy = composition.retryPolicy
        self.taskExecutor = composition.taskExecutor
        self.processItemOverride = processItemOverride
        self.verifiedOwner = verifiedOwner
        updateQueueMetrics()
    }
}
