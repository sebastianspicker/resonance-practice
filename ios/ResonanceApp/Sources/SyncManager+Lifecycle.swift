import Foundation
import UIKit

// Drives owner-scoped queue lifecycle, background execution, and ready-work retrieval.

@MainActor
extension SyncManager {
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
            // Use DispatchQueue.main.async rather than Task { @MainActor } so
            // expiration does not queue behind the active sync operation.
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
