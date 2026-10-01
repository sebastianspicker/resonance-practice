import SwiftData
import SwiftUI

// Shows queued synchronization work and lets the user process or retry it.

struct SyncQueueView: View {
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.capturePresentation) private var capturePresentation
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
        guard capturePresentation else { return syncManager.pendingQueueCount }
        return queueItems.filter { $0.status == "pending" || $0.status == "processing" }.count
    }

    private var failedQueueCount: Int {
        guard capturePresentation else { return syncManager.failedQueueCount }
        return queueItems.filter { $0.status == "failed" }.count
    }

    private func processQueue() { Task { await syncManager.processQueue() } }
    private func retryFailed() { syncManager.retryFailedItems() }
}
