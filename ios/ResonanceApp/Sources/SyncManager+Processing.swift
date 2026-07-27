import Foundation

// Implements ownership- and generation-guarded queue passes for the sync coordinator.

private struct CommandCollection {
    let candidates: [(item: SyncQueueItem, command: SyncCommand)]
    let handled: Set<String>
    let deferredItemIDs: Set<String>
}

@MainActor
extension SyncManager {
    /// Processes only work still owned by the authenticated profile and current generation.
    func process(items: [SyncQueueItem], ownerId: String, processingGeneration: Int) async {
        let commandItemIDs = await processCommandBatches(
            items,
            ownerId: ownerId,
            processingGeneration: processingGeneration
        )
        await processNonCommandItems(
            items,
            excluding: commandItemIDs,
            ownerId: ownerId,
            processingGeneration: processingGeneration
        )
    }

    private func processNonCommandItems(
        _ items: [SyncQueueItem],
        excluding commandItemIDs: Set<String>,
        ownerId: String,
        processingGeneration: Int
    ) async {
        for item in items {
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId), item.ownerId == ownerId else {
                return
            }
            guard !commandItemIDs.contains(item.id) else { continue }
            let shouldContinue = await processNonCommandItem(
                item,
                ownerId: ownerId,
                processingGeneration: processingGeneration
            )
            guard shouldContinue else { return }
        }
    }

    private func processNonCommandItem(
        _ item: SyncQueueItem,
        ownerId: String,
        processingGeneration: Int
    ) async -> Bool {
        do {
            await authManager.refreshIfNeeded()
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId),
                  let accessToken = authManager.session?.accessToken else {
                Self.logger.warning("Lost auth session mid-sync; aborting remaining items")
                return false
            }
            item.status = SyncStatus.processing.rawValue
            if let processItemOverride {
                try await processItemOverride(item, accessToken)
            } else {
                try await taskExecutor.execute(item: item, accessToken: accessToken)
            }
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId) else { return false }
            store.delete(item)
            return true
        } catch {
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId) else { return false }
            return handleNonCommandFailure(error, item: item)
        }
    }

    private func handleNonCommandFailure(_ error: Error, item: SyncQueueItem) -> Bool {
        if case SyncError.dependenciesPending = error {
            item.status = SyncStatus.pending.rawValue
            item.lastError = nil
            item.nextAttemptAt = Date().addingTimeInterval(2)
            return true
        }
        if let apiError = error as? APIError, isSessionBoundaryError(apiError) {
            item.status = SyncStatus.pending.rawValue
            item.lastError = apiError.error.code
            item.nextAttemptAt = nil
            authManager.signOut()
            return false
        }
        item.retryCount += 1
        item.lastError = stableErrorDescription(error)
        if item.retryCount >= retryPolicy.maxAttempts || retryPolicy.isTerminal(error) {
            item.status = SyncStatus.failed.rawValue
            store.updateArtifactFailureIfNeeded(item: item)
            return true
        }
        item.status = SyncStatus.pending.rawValue
        item.nextAttemptAt = Date().addingTimeInterval(retryPolicy.backoffDelay(retryCount: item.retryCount))
        store.resetArtifactStateForRetryIfNeeded(item: item)
        return false
    }

    /// Sends command-compatible work in bounded batches. Media uploads retain
    /// their dedicated presigned-upload path and are handled by the loop above.
    func processCommandBatches(
        _ items: [SyncQueueItem],
        ownerId: String,
        processingGeneration: Int
    ) async -> Set<String> {
        guard processItemOverride == nil else { return [] }
        let collected = collectCommands(items, ownerId: ownerId, processingGeneration: processingGeneration)
        var handled = collected.handled
        if !collected.deferredItemIDs.isEmpty {
            needsAnotherQueuePass = true
            handled.formUnion(collected.deferredItemIDs)
        }
        for batch in collected.candidates.chunked(into: 25) {
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId) else { return handled }
            for pair in batch { pair.item.queueStatus = .processing }
            let batchHandled = await processCommandBatch(
                batch,
                ownerId: ownerId,
                processingGeneration: processingGeneration
            )
            handled.formUnion(batchHandled)
            if batchHandled.count != batch.count { return handled }
        }
        return handled
    }

    private func collectCommands(
        _ items: [SyncQueueItem],
        ownerId: String,
        processingGeneration: Int
    ) -> CommandCollection {
        var candidates: [(item: SyncQueueItem, command: SyncCommand)] = []
        var handled: Set<String> = []
        var entityIDsInWave: Set<String> = []
        var deferredItemIDs: Set<String> = []
        for item in items where isProcessingCurrent(processingGeneration, ownerId: ownerId) && item.ownerId == ownerId {
            do {
                if let entityID = try taskExecutor.commandEntityID(for: item), !entityIDsInWave.insert(entityID).inserted {
                    deferredItemIDs.insert(item.id)
                } else if let command = try taskExecutor.command(for: item) {
                    candidates.append((item, command))
                }
            } catch {
                handleFailure(error, for: item)
                handled.insert(item.id)
            }
        }
        return CommandCollection(
            candidates: candidates,
            handled: handled,
            deferredItemIDs: deferredItemIDs
        )
    }

    private func processCommandBatch(
        _ batch: [(item: SyncQueueItem, command: SyncCommand)],
        ownerId: String,
        processingGeneration: Int
    ) async -> Set<String> {
        do {
            await authManager.refreshIfNeeded()
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId),
                  let accessToken = authManager.session?.accessToken else { return [] }
            let response = try await apiClient.sendSyncCommands(
                accessToken: accessToken,
                commands: batch.map(\.command)
            )
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId) else { return [] }
            return applyCommandResults(response, batch: batch, ownerId: ownerId, processingGeneration: processingGeneration)
        } catch {
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId) else { return [] }
            for pair in batch { handleFailure(error, for: pair.item) }
            return Set(batch.map { $0.item.id })
        }
    }

    private func applyCommandResults(
        _ response: SyncCommandsResponse,
        batch: [(item: SyncQueueItem, command: SyncCommand)],
        ownerId: String,
        processingGeneration: Int
    ) -> Set<String> {
        let results = Dictionary(uniqueKeysWithValues: response.results.map { ($0.operationId, $0) })
        var handled: Set<String> = []
        for pair in batch {
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId), pair.item.ownerId == ownerId else {
                return handled
            }
            guard let result = results[pair.item.id] else {
                handleFailure(SyncError.commandRetryable("Missing result for \(pair.item.id)."), for: pair.item)
                handled.insert(pair.item.id)
                continue
            }
            do {
                try taskExecutor.apply(result, for: pair.item)
                store.delete(pair.item)
            } catch {
                handleFailure(error, for: pair.item)
            }
            handled.insert(pair.item.id)
        }
        return handled
    }

    private func handleFailure(_ error: Error, for item: SyncQueueItem) {
        if case SyncError.dependenciesPending = error {
            item.queueStatus = .pending
            item.lastError = nil
            item.nextAttemptAt = Date().addingTimeInterval(2)
            return
        }
        item.retryCount += 1
        item.lastError = stableErrorDescription(error)
        if case let SyncError.serverConflict(entityId, _) = error {
            conflictedEntryIDs.insert(entityId)
        }
        if item.retryCount >= retryPolicy.maxAttempts || retryPolicy.isTerminal(error) {
            item.queueStatus = .failed
            store.updateArtifactFailureIfNeeded(item: item)
        } else {
            item.queueStatus = .pending
            item.nextAttemptAt = Date().addingTimeInterval(retryPolicy.backoffDelay(retryCount: item.retryCount))
            store.resetArtifactStateForRetryIfNeeded(item: item)
        }
    }

    private func stableErrorDescription(_ error: Error) -> String {
        (error as? APIError)?.error.code ?? error.localizedDescription
    }

    private func isSessionBoundaryError(_ error: APIError) -> Bool {
        let boundaryCodes: Set<String> = [
            "MISSING_AUTH",
            "INVALID_TOKEN",
            "INVALID_REFRESH",
            "REFRESH_REVOKED",
            "REFRESH_MISMATCH",
            "REFRESH_ALREADY_USED",
            "USER_NOT_FOUND"
        ]
        return boundaryCodes.contains(error.error.code)
    }

    func finishQueuePass(_ items: [SyncQueueItem]) {
        if !items.isEmpty { lastSyncedAt = Date() }
        store.save()
        updateQueueMetrics()
    }

    func updateQueueMetrics() {
        let (pending, failed) = store.counts(ownerId: authorizedOwner())
        pendingQueueCount = pending
        failedQueueCount = failed
    }

    func authorizedOwner() -> String? {
        guard let sessionUserId = authManager.session?.userId,
              !sessionUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let storedOwner = try? verifiedOwner(),
              storedOwner == sessionUserId else { return nil }
        return sessionUserId
    }

    func isProcessingCurrent(_ generation: Int, ownerId: String) -> Bool {
        processingGeneration == generation && authorizedOwner() == ownerId
    }
}
