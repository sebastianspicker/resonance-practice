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
        guard let accessToken = await passAccessToken(
            ownerId: ownerId, processingGeneration: processingGeneration
        ) else {
            Self.logger.warning("Lost auth session mid-sync; aborting remaining items")
            return false
        }
        do {
            item.status = SyncStatus.processing.rawValue
            if let processItemOverride {
                try await processItemOverride(item, accessToken)
            } else {
                try await taskExecutor.execute(
                    item: item,
                    accessToken: accessToken,
                    freshAccessToken: { [weak self] in
                        await self?.freshAccessToken(ownerId: ownerId)
                    }
                )
            }
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId) else { return false }
            store.delete(item)
            return true
        } catch {
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId) else { return false }
            if await deferForAccessTokenRejection(error, items: [item], rejectedToken: accessToken) {
                return false
            }
            return handleNonCommandFailure(error, item: item)
        }
    }

    /// Refreshes if needed and returns the access token while this pass is still current.
    private func passAccessToken(ownerId: String, processingGeneration: Int) async -> String? {
        await authManager.refreshIfNeeded()
        guard isProcessingCurrent(processingGeneration, ownerId: ownerId) else { return nil }
        return authManager.session?.accessToken
    }

    /// Refreshes if needed and returns the access token only while `ownerId` is still signed in.
    private func freshAccessToken(ownerId: String) async -> String? {
        await authManager.refreshIfNeeded()
        guard let session = authManager.session, session.userId == ownerId else { return nil }
        return session.accessToken
    }

    /// A rejected access token is recoverable: keep the work pending without spending a retry,
    /// refresh, and let the caller stop this pass. Only a rejected refresh token ends the session,
    /// which `AuthManager` decides. The refresh is forced only while the rejected token is still
    /// current, so a token another caller already rotated is not rotated again.
    private func deferForAccessTokenRejection(
        _ error: Error,
        items: [SyncQueueItem],
        rejectedToken: String
    ) async -> Bool {
        guard let apiError = error as? APIError, isAccessTokenRejection(apiError) else { return false }
        for item in items {
            item.queueStatus = .pending
            item.lastError = apiError.error.code
            item.nextAttemptAt = nil
            store.resetArtifactStateForRetryIfNeeded(item: item)
        }
        let isStillCurrent = authManager.session?.accessToken == rejectedToken
        await authManager.refreshIfNeeded(force: isStillCurrent)
        return true
    }

    private func handleNonCommandFailure(_ error: Error, item: SyncQueueItem) -> Bool {
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
            guard let batchHandled = await processCommandBatch(
                batch,
                ownerId: ownerId,
                processingGeneration: processingGeneration
            ) else {
                // Access token rejected: stop sending batches this pass (later batches were never
                // marked processing), and keep every command item out of the non-command path.
                return handled.union(collected.candidates.map(\.item.id))
            }
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

    /// Returns the handled item IDs, or nil when the access token was rejected and the pass should stop.
    private func processCommandBatch(
        _ batch: [(item: SyncQueueItem, command: SyncCommand)],
        ownerId: String,
        processingGeneration: Int
    ) async -> Set<String>? {
        guard let accessToken = await passAccessToken(
            ownerId: ownerId, processingGeneration: processingGeneration
        ) else { return [] }
        do {
            let response = try await apiClient.sendSyncCommands(
                accessToken: accessToken,
                commands: batch.map(\.command)
            )
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId) else { return [] }
            return applyCommandResults(response, batch: batch, ownerId: ownerId, processingGeneration: processingGeneration)
        } catch {
            guard isProcessingCurrent(processingGeneration, ownerId: ownerId) else { return [] }
            if await deferForAccessTokenRejection(
                error, items: batch.map(\.item), rejectedToken: accessToken
            ) {
                return nil
            }
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

    /// The access token was rejected; a refresh can recover the session.
    private func isAccessTokenRejection(_ error: APIError) -> Bool {
        ["MISSING_AUTH", "INVALID_TOKEN"].contains(error.error.code)
    }

    /// The refresh token or account is gone; the session cannot recover.
    private func isSessionBoundaryError(_ error: APIError) -> Bool {
        AuthManager.refreshRejectionCodes.contains(error.error.code)
    }

    func finishQueuePass(_ items: [SyncQueueItem]) {
        if !items.isEmpty { lastSyncedAt = Date() }
        store.save()
        updateQueueMetrics()
        // A capped ready window may leave FIFO work behind it. Continue inside
        // this processing session so a separate lifecycle event is not required.
        if items.count == QueueStore.maxReadyWindow { needsAnotherQueuePass = true }
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
