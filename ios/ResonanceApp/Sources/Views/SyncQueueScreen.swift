import SwiftData
import SwiftUI

// Owns live queue observation, screenshot-aware counts, and retry/process actions.

struct SyncQueueScreen: View {
    @EnvironmentObject var syncManager: SyncManager
    @Query(sort: \SyncQueueItem.createdAt, order: .reverse) private var queueItems: [SyncQueueItem]

    private var queueState: SyncQueueState {
        SyncQueueState(
            items: queueItems,
            pendingCount: pendingQueueCount,
            failedCount: failedQueueCount
        )
    }

    var body: some View {
        NavigationStack {
            SyncQueueContent(state: queueState)
                .scrollContentBackground(.hidden)
                .background(AppTheme.workspaceBackground)
                .navigationTitle("Sync status")
                .toolbar {
                    SyncQueueToolbar(
                        isQueueEmpty: queueState.isEmpty,
                        failedCount: queueState.failedCount,
                        processQueue: processQueue,
                        retryFailed: retryFailed
                    )
                }
        }
    }

    private var pendingQueueCount: Int {
        guard ScreenshotScenario.current != nil else { return syncManager.pendingQueueCount }
        return queueItems.filter { $0.status == "pending" || $0.status == "processing" }.count
    }

    private var failedQueueCount: Int {
        guard ScreenshotScenario.current != nil else { return syncManager.failedQueueCount }
        return queueItems.filter { $0.status == "failed" }.count
    }

    private func processQueue() { Task { await syncManager.processQueue() } }
    private func retryFailed() { syncManager.retryFailedItems() }
}
