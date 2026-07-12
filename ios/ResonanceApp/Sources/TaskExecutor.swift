import Foundation
import os
import SwiftData

/// Executes a single sync task against the API server.
///
/// `SyncManager` creates one `TaskExecutor` and calls `execute(item:accessToken:)`
/// for each queue item.  All networking and SwiftData side-effects live here;
/// `SyncManager` only coordinates auth, retry, and queue state.
///
/// ## Retry contract
/// Queue items may run more than once after transient failures, so each task
/// documents how duplicate work is handled:
/// - `createEntry`: server returns **409 Conflict** on
///   duplicate client-generated UUIDs; the client treats 409 as success.
/// - `syncArtifact`: duplicate artifact creation is safe, but presign/confirm
///   state still comes from the server and should not be treated as a pure PUT.
/// - `syncCaptureProfile`: idempotently patches one teaching-lesson metadata field.
/// - `syncCaptureMarkers`: marker IDs are client-generated and the server upserts them.
/// - `submitEntry`: repeated submits can return `ENTRY_LOCKED` once the server
///   has already moved the entry out of `draft`.
/// - `deleteEntry`: missing or already-deleted entries are treated as success.
/// - `postFeedback`: sends the local feedback ID as an idempotency key so a
///   timeout after server-side creation can safely retry.
@MainActor
final class TaskExecutor {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "resonance",
        category: "TaskExecutor"
    )
    private let apiClient: APIClient
    private let store: QueueStore
    private let session: URLSession

    init(apiClient: APIClient, store: QueueStore, session: URLSession) {
        self.apiClient = apiClient
        self.store = store
        self.session = session
    }

    // MARK: - Public API

    func execute(item: SyncQueueItem, accessToken: String) async throws {
        guard let data = item.payloadJSON.data(using: .utf8) else {
            throw SyncError.payloadParseError("Failed to convert payload to data")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.payloadParseError("Failed to parse payload as JSON dictionary")
        }
        guard let taskType = SyncTaskType(rawValue: item.type) else {
            throw SyncError.unknownTaskType("Unknown sync task type: \(item.type)")
        }

        try await execute(taskType: taskType, payload: payload, accessToken: accessToken)
    }

    // MARK: - Private helpers

    private func execute(taskType: SyncTaskType, payload: [String: Any], accessToken: String) async throws {
        switch taskType {
        case .createEntry: try await executeCreateEntry(payload: payload, accessToken: accessToken)
        case .updateEntry: try await executeUpdateEntry(payload: payload, accessToken: accessToken)
        case .submitEntry: try await executeSubmitEntry(payload: payload, accessToken: accessToken)
        case .deleteEntry: try await executeDeleteEntry(payload: payload, accessToken: accessToken)
        case .syncArtifact: try await executeSyncArtifact(payload: payload, accessToken: accessToken)
        case .syncCaptureProfile: try await executeSyncCaptureProfile(payload: payload, accessToken: accessToken)
        case .syncCaptureMarkers: try await executeSyncCaptureMarkers(payload: payload, accessToken: accessToken)
        case .postFeedback: try await executePostFeedback(payload: payload, accessToken: accessToken)
        }
    }

    private func executeCreateEntry(payload: [String: Any], accessToken: String) async throws {
        let entryId = payload["entryId"] as? String ?? ""
        let entry = try store.fetchEntry(id: entryId)
        do {
            _ = try await apiClient.createEntry(accessToken: accessToken, courseId: entry.courseId, entry: entry)
        } catch let error as APIError where error.error.code == "ID_CONFLICT" {
            return
        }
    }

    private func executeUpdateEntry(payload: [String: Any], accessToken: String) async throws {
        let entryId = payload["entryId"] as? String ?? ""
        let entry = try store.fetchEntry(id: entryId)
        let response = try await apiClient.updateEntry(accessToken: accessToken, entry: entry)
        entry.remoteUpdatedAt = response.updatedAt ?? Date()
        store.save()
    }

    private func executeSubmitEntry(payload: [String: Any], accessToken: String) async throws {
        let entryId = payload["entryId"] as? String ?? ""
        let entry = try store.fetchEntry(id: entryId)
        guard !entry.artifacts.isEmpty,
              entry.artifacts.allSatisfy({ $0.uploadState == .uploaded }) else {
            throw SyncError.dependenciesPending("Submission is waiting for media uploads")
        }
        _ = try await apiClient.submitEntry(accessToken: accessToken, entryId: entryId)
        entry.status = .submitted
        store.save()
    }

    private func executeDeleteEntry(payload: [String: Any], accessToken: String) async throws {
        let entryId = payload["entryId"] as? String ?? ""
        do {
            try await apiClient.deleteEntry(accessToken: accessToken, entryId: entryId)
        } catch let error as APIError
            where error.error.code == "ENTRY_NOT_FOUND" || error.error.code == "ENTRY_DELETED" {
            return
        }
    }

    private func executeSyncArtifact(payload: [String: Any], accessToken: String) async throws {
        let artifactId = payload["artifactId"] as? String ?? ""
        let artifact = try store.fetchArtifact(id: artifactId)

        do {
            _ = try await apiClient.createArtifact(accessToken: accessToken, entryId: artifact.entryId, artifact: artifact)
        } catch let error as APIError where error.error.code == "ID_CONFLICT" {
            // Already exists on server — continue to upload.
        }

        artifact.uploadState = .uploading
        artifact.syncPhase = .uploading
        store.save()

        guard FileManager.default.fileExists(atPath: artifact.localPath) else {
            throw SyncError.localFileNotFound("Local file not found for artifact \(artifactId) at \(artifact.localPath)")
        }

        let presign = try await apiClient.presignArtifact(accessToken: accessToken, artifactId: artifact.id)
        guard let uploadURL = URL(string: presign.uploadUrl), uploadURL.scheme != nil else {
            throw SyncError.invalidPresignUrl("Invalid presign URL for artifact \(artifactId)")
        }
        try await uploadFile(url: uploadURL, fileURL: URL(fileURLWithPath: artifact.localPath), requiredHeaders: presign.requiredHeaders ?? [:])
        artifact.syncPhase = .confirming
        store.save()

        let response = try await apiClient.confirmArtifact(accessToken: accessToken, artifactId: artifactId)
        artifact.uploadState = UploadState(rawValue: response.uploadState) ?? .uploaded
        artifact.syncPhase = .uploaded
        artifact.storageKey = response.storageKey
        artifact.remoteUrl = response.remoteUrl
        store.save()
    }

    private func executeSyncCaptureProfile(payload: [String: Any], accessToken: String) async throws {
        let entryId = payload["entryId"] as? String ?? ""
        let entry = try store.fetchEntry(id: entryId)
        _ = try await apiClient.updateEntryCaptureProfile(
            accessToken: accessToken,
            entryId: entryId,
            captureProfile: entry.captureProfile
        )
    }

    private func executeSyncCaptureMarkers(payload: [String: Any], accessToken: String) async throws {
        let entryId = payload["entryId"] as? String ?? ""
        _ = try store.fetchEntry(id: entryId)
        let markers = try store.fetchCaptureMarkers(entryId: entryId)
        _ = try await apiClient.syncCaptureMarkers(
            accessToken: accessToken,
            entryId: entryId,
            markers: markers
        )
    }

    private func executePostFeedback(payload: [String: Any], accessToken: String) async throws {
        let targetType = payload["targetType"] as? String ?? "entry"
        let targetId = payload["targetId"] as? String ?? ""
        let feedbackId = payload["feedbackId"] as? String ?? ""

        let descriptor = FetchDescriptor<LocalFeedback>(predicate: #Predicate { $0.id == feedbackId })
        let feedback: LocalFeedback
        do {
            feedback = try store.fetchFirst(descriptor)
        } catch {
            throw SyncError.localFeedbackNotFound("Local feedback not found: \(feedbackId)")
        }
        let status = feedback.status
        let commentsText = feedback.commentsText
        let markers = feedback.markers
        _ = try await apiClient.createFeedback(
            accessToken: accessToken,
            submission: FeedbackSubmission(
                feedbackId: feedback.id,
                targetType: targetType,
                targetId: targetId,
                status: status,
                commentsText: commentsText,
                markers: markers
            )
        )

        if targetType == "entry", let entry = try? store.fetchEntry(id: targetId) {
            entry.status = .reviewed
            store.save()
        } else if targetType == "artifact",
                  let artifact = try? store.fetchArtifact(id: targetId),
                  let entry = try? store.fetchEntry(id: artifact.entryId) {
            entry.status = .reviewed
            store.save()
        }
    }

    private func uploadFile(url: URL, fileURL: URL, requiredHeaders: [String: String]) async throws {
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
