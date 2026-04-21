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
    case createArtifact
    case uploadArtifact
    case confirmArtifact
    case submitEntry
    case deleteEntry
    case postFeedback
    case syncArtifact
}

/// Errors that can occur during sync operations
enum SyncError: LocalizedError {
    case payloadParseError(String)
    case unknownTaskType(String)
    case localFileNotFound(String)
    case invalidPresignUrl(String)
    case localFeedbackNotFound(String)

    var errorDescription: String? {
        switch self {
        case .payloadParseError(let message): return message
        case .unknownTaskType(let message): return message
        case .localFileNotFound(let message): return message
        case .invalidPresignUrl(let message): return message
        case .localFeedbackNotFound(let message): return message
        }
    }
}

@MainActor
final class SyncManager: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "SyncManager")
    private let apiClient: APIClient
    private let modelContext: ModelContext
    private let authManager: AuthManager
    private let networkMonitor: NetworkMonitor
    private let session: URLSession

    @Published var lastSyncedAt: Date?
    @Published var pendingQueueCount: Int = 0
    @Published var failedQueueCount: Int = 0

    init(modelContext: ModelContext, authManager: AuthManager, apiClient: APIClient, networkMonitor: NetworkMonitor = NetworkMonitor()) {
        self.modelContext = modelContext
        self.authManager = authManager
        self.apiClient = apiClient
        self.networkMonitor = networkMonitor
        // Use a standard (non-background) session configuration. Background
        // URLSession does NOT support the async upload(for:fromFile:) API and
        // would throw at runtime. Extended execution time is already handled
        // by UIApplication.beginBackgroundTask in processQueue().
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        updateQueueMetrics()
    }

    /// Enqueue a sync task for later processing.
    ///
    /// - Important: If the payload cannot be serialized to JSON, the item is
    ///   **not** silently dropped. An error is logged so developers can diagnose
    ///   the issue (e.g., non-serializable values in the dictionary).
    func enqueue(type: SyncTaskType, payload: [String: Any]) {
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
        let item = SyncQueueItem(id: UUID().uuidString, type: type.rawValue, payloadJSON: json)
        modelContext.insert(item)
        saveContext()
        updateQueueMetrics()
    }

    func retryFailedItems() {
        let failedValue = SyncStatus.failed.rawValue
        let descriptor = FetchDescriptor<SyncQueueItem>(predicate: #Predicate { $0.status == failedValue })
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
        }
        saveContext()
        updateQueueMetrics()
    }

    func processQueue() async {
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
                guard let self else { return }
                let processingValue = SyncStatus.processing.rawValue
                let stuckDescriptor = FetchDescriptor<SyncQueueItem>(predicate: #Predicate { $0.status == processingValue })
                do {
                    let stuck = try self.modelContext.fetch(stuckDescriptor)
                    for item in stuck {
                        item.status = SyncStatus.pending.rawValue
                        item.nextAttemptAt = nil
                    }
                    if !stuck.isEmpty { self.saveContext() }
                } catch {
                    Self.logger.error("Failed to fetch stuck sync items on background expiry: \(error.localizedDescription)")
                }
            }
        }

        defer {
            UIApplication.shared.endBackgroundTask(taskId)
        }

        await authManager.refreshIfNeeded()
        guard authManager.session?.accessToken != nil else { return }
        let now = Date()
        let pendingValue = SyncStatus.pending.rawValue
        var descriptor = FetchDescriptor<SyncQueueItem>(predicate: #Predicate { item in
            item.status == pendingValue && (item.nextAttemptAt == nil || (item.nextAttemptAt ?? .distantFuture) <= now)
        })
        // Sort by creation time to preserve FIFO ordering. Without this,
        // dependent items (e.g., uploadArtifact before createArtifact has
        // succeeded) could be processed out of order on retry.
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .forward)]
        let items: [SyncQueueItem]
        do {
            items = try modelContext.fetch(descriptor)
        } catch {
            Self.logger.error("Failed to fetch pending sync items: \(error.localizedDescription)")
            return
        }

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
                try await process(item: item, accessToken: accessToken)
                modelContext.delete(item)
            } catch {
                item.retryCount += 1
                item.lastError = String(describing: error)

                if item.retryCount >= 20 {
                    item.status = SyncStatus.failed.rawValue
                    updateArtifactFailureIfNeeded(item: item)
                    continue
                }

                // If it's a specific validation/client error, don't retry forever.
                if let apiError = error as? APIError, apiError.error.code == "VALIDATION_ERROR" {
                    item.status = SyncStatus.failed.rawValue
                } else if (error as NSError).domain == "SyncLocal" && (error as NSError).code == 404 {
                    item.status = SyncStatus.failed.rawValue // Item missing locally (via fetchFirst), can't sync.
                } else if error is SyncError {
                    item.status = SyncStatus.failed.rawValue // Any typed SyncError (missing local data, bad payload) is non-retryable.
                } else {
                    item.status = SyncStatus.pending.rawValue
                    let delay = min(pow(2.0, Double(item.retryCount)), 300)
                    item.nextAttemptAt = Date().addingTimeInterval(delay)
                }
                updateArtifactFailureIfNeeded(item: item)
            }
        }
        if !items.isEmpty {
            lastSyncedAt = Date()
        }
        saveContext()
        updateQueueMetrics()
    }

    /// Execute a single sync task against the server.
    ///
    /// ## Idempotency contract
    /// Because items may be retried after transient failures, the server **must**
    /// handle duplicate requests gracefully:
    /// - `createEntry` / `createArtifact`: If the resource already exists (same
    ///   client-generated UUID), the server should return **409 Conflict** (not
    ///   500) so the client can treat it as a success and remove the queue item.
    /// - `confirmArtifact` / `submitEntry`: These are inherently idempotent
    ///   (re-confirming or re-submitting yields the same state).
    /// - `deleteEntry`: Deleting an already-deleted resource should return 200 or
    ///   204, not 404, to avoid permanent "failed" items in the queue.
    /// - `uploadArtifact`: S3 PUT is naturally idempotent (same key overwrites).
    /// - `postFeedback`: Server should upsert by feedback ID to avoid duplicates.
    private func process(item: SyncQueueItem, accessToken: String) async throws {
        // Parse payload - throw error instead of silent return on failure
        guard let data = item.payloadJSON.data(using: .utf8) else {
            throw SyncError.payloadParseError("Failed to convert payload to data")
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.payloadParseError("Failed to parse payload as JSON dictionary")
        }

        // Validate task type - throw error for unknown types
        guard let taskType = SyncTaskType(rawValue: item.type) else {
            throw SyncError.unknownTaskType("Unknown sync task type: \(item.type)")
        }

        switch taskType {
        case .createEntry:
            let entryId = payload["entryId"] as? String ?? ""
            let entry = try fetchEntry(id: entryId)
            _ = try await apiClient.createEntry(accessToken: accessToken, courseId: entry.courseId, entry: entry)

        case .createArtifact:
            let artifactId = payload["artifactId"] as? String ?? ""
            let artifact = try fetchArtifact(id: artifactId)
            _ = try await apiClient.createArtifact(accessToken: accessToken, entryId: artifact.entryId, artifact: artifact)
            artifact.syncPhase = .queued
            saveContext()

        case .uploadArtifact:
            let artifactId = payload["artifactId"] as? String ?? ""
            let artifact = try fetchArtifact(id: artifactId)
            artifact.uploadState = .uploading
            artifact.syncPhase = .uploading
            saveContext()

            // Fail fast before requesting a presign URL: missing file can't be recovered by retry.
            guard FileManager.default.fileExists(atPath: artifact.localPath) else {
                throw SyncError.localFileNotFound("Local file not found for artifact \(artifactId) at \(artifact.localPath)")
            }

            let presign = try await apiClient.presignArtifact(accessToken: accessToken, artifactId: artifact.id)

            guard let uploadURL = URL(string: presign.uploadUrl), uploadURL.scheme != nil else {
                throw SyncError.invalidPresignUrl("Invalid presign URL for artifact \(artifactId)")
            }

            try await uploadFile(
                url: uploadURL,
                fileURL: URL(fileURLWithPath: artifact.localPath),
                requiredHeaders: presign.requiredHeaders ?? [:]
            )
            artifact.syncPhase = .confirming
            saveContext()

        case .confirmArtifact:
            let artifactId = payload["artifactId"] as? String ?? ""
            let response = try await apiClient.confirmArtifact(accessToken: accessToken, artifactId: artifactId)
            let artifact = try fetchArtifact(id: artifactId)
            artifact.uploadState = UploadState(rawValue: response.uploadState) ?? .uploaded
            artifact.syncPhase = .uploaded
            artifact.storageKey = response.storageKey
            artifact.remoteUrl = response.remoteUrl
            saveContext()

        case .submitEntry:
            let entryId = payload["entryId"] as? String ?? ""
            _ = try await apiClient.submitEntry(accessToken: accessToken, entryId: entryId)
            let entry = try fetchEntry(id: entryId)
            entry.status = .submitted
            saveContext()

        case .deleteEntry:
            let entryId = payload["entryId"] as? String ?? ""
            try await apiClient.deleteEntry(accessToken: accessToken, entryId: entryId)

        case .syncArtifact:
            let artifactId = payload["artifactId"] as? String ?? ""
            let artifact = try fetchArtifact(id: artifactId)

            // Step 1: Create artifact on server (409 = already exists, continue to upload)
            do {
                _ = try await apiClient.createArtifact(accessToken: accessToken, entryId: artifact.entryId, artifact: artifact)
            } catch let error as APIError where error.error.code == "ID_CONFLICT" {
                // Artifact already exists on server, continue to upload step
            }
            artifact.syncPhase = .queued
            saveContext()

            // Step 2: Upload artifact file
            artifact.uploadState = .uploading
            artifact.syncPhase = .uploading
            saveContext()

            guard FileManager.default.fileExists(atPath: artifact.localPath) else {
                throw SyncError.localFileNotFound("Local file not found for artifact \(artifactId) at \(artifact.localPath)")
            }

            let presign = try await apiClient.presignArtifact(accessToken: accessToken, artifactId: artifact.id)

            guard let uploadURL = URL(string: presign.uploadUrl), uploadURL.scheme != nil else {
                throw SyncError.invalidPresignUrl("Invalid presign URL for artifact \(artifactId)")
            }

            try await uploadFile(
                url: uploadURL,
                fileURL: URL(fileURLWithPath: artifact.localPath),
                requiredHeaders: presign.requiredHeaders ?? [:]
            )
            artifact.syncPhase = .confirming
            saveContext()

            // Step 3: Confirm artifact upload
            let response = try await apiClient.confirmArtifact(accessToken: accessToken, artifactId: artifactId)
            artifact.uploadState = UploadState(rawValue: response.uploadState) ?? .uploaded
            artifact.syncPhase = .uploaded
            artifact.storageKey = response.storageKey
            artifact.remoteUrl = response.remoteUrl
            saveContext()

        case .postFeedback:
            let targetType = payload["targetType"] as? String ?? "entry"
            let targetId = payload["targetId"] as? String ?? ""
            let feedbackId = payload["feedbackId"] as? String ?? ""

            // Fetch the local feedback to get markers
            let descriptor = FetchDescriptor<LocalFeedback>(predicate: #Predicate { $0.id == feedbackId })
            guard let feedback = try modelContext.fetch(descriptor).first else {
                throw SyncError.localFeedbackNotFound("Local feedback not found: \(feedbackId)")
            }
            let status = feedback.status
            let commentsText = feedback.commentsText
            let markers = feedback.markers
            _ = try await apiClient.createFeedback(accessToken: accessToken, targetType: targetType, targetId: targetId, status: status, commentsText: commentsText, markers: markers)
            if targetType == "entry", let entry = try? fetchEntry(id: targetId) {
                entry.status = .reviewed
                saveContext()
            } else if targetType == "artifact", let artifact = try? fetchArtifact(id: targetId), let entry = try? fetchEntry(id: artifact.entryId) {
                entry.status = .reviewed
                saveContext()
            }
        }
    }

    private func fetchFirst<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> T {
        guard let first = try modelContext.fetch(descriptor).first else {
            throw NSError(domain: "SyncLocal", code: 404, userInfo: [NSLocalizedDescriptionKey: "Item not found in local DB"])
        }
        return first
    }

    private func fetchEntry(id: String) throws -> LocalPracticeEntry {
        try fetchFirst(FetchDescriptor<LocalPracticeEntry>(predicate: #Predicate { $0.id == id }))
    }

    private func fetchArtifact(id: String) throws -> LocalArtifact {
        try fetchFirst(FetchDescriptor<LocalArtifact>(predicate: #Predicate { $0.id == id }))
    }

    private func updateArtifactFailureIfNeeded(item: SyncQueueItem) {
        guard item.type == SyncTaskType.createArtifact.rawValue ||
                item.type == SyncTaskType.uploadArtifact.rawValue ||
                item.type == SyncTaskType.confirmArtifact.rawValue ||
                item.type == SyncTaskType.syncArtifact.rawValue else {
            return
        }
        guard let data = item.payloadJSON.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let artifactId = payload["artifactId"] as? String,
              let artifact = try? fetchArtifact(id: artifactId) else {
            return
        }
        artifact.uploadState = .failed
        artifact.syncPhase = .failed
        saveContext()
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Failed to save model context: \(error.localizedDescription)")
        }
    }

    private func updateQueueMetrics() {
        let pendingValue = SyncStatus.pending.rawValue
        let processingValue = SyncStatus.processing.rawValue
        let failedValue = SyncStatus.failed.rawValue
        let pendingDescriptor = FetchDescriptor<SyncQueueItem>(predicate: #Predicate {
            $0.status == pendingValue || $0.status == processingValue
        })
        let failedDescriptor = FetchDescriptor<SyncQueueItem>(predicate: #Predicate { $0.status == failedValue })
        do {
            // Note: fetchCount (available on iOS 17+) would be more efficient here
            // since we only need the count, not the full model objects. For now, fetching
            // all rows and taking .count is correct but loads unnecessary data.
            pendingQueueCount = try modelContext.fetch(pendingDescriptor).count
            failedQueueCount = try modelContext.fetch(failedDescriptor).count
        } catch {
            Self.logger.error("Failed to update queue metrics: \(error.localizedDescription)")
        }
    }

    private func uploadFile(
        url: URL,
        fileURL: URL,
        requiredHeaders: [String: String]
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (header, value) in requiredHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
    }
}
