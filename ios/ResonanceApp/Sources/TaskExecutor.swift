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
/// - `createEntry`: the server treats exact repeats as idempotent; an ID conflict
///   is accepted only after the remote entry is proven to match the local create.
/// - `syncArtifact`: exact artifact retries are idempotent, but presign/confirm
///   state still comes from the server and is reconciled before continuing.
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
        let response: EntryResponse
        do {
            response = try await apiClient.createEntry(
                accessToken: accessToken,
                courseId: entry.courseId,
                entry: entry
            )
        } catch let error as APIError where error.error.code == "ID_CONFLICT" {
            let remote = try await apiClient.fetchEntry(accessToken: accessToken, entryId: entryId)
            guard isExactCreateRetry(remote: remote, local: entry) else {
                throw error
            }
            response = remote
        }
        entry.remoteUpdatedAt = response.updatedAt ?? response.createdAt ?? Date()
        store.save()
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
        do {
            _ = try await apiClient.submitEntry(accessToken: accessToken, entryId: entryId)
            entry.status = .submitted
            store.save()
        } catch let error as APIError where error.error.code == "ENTRY_LOCKED" {
            // A lost submit response can leave this queue item pending even
            // though the server already moved the entry out of draft. Fetch
            // the authoritative state instead of turning that successful
            // operation into a terminal local failure.
            let remote = try await apiClient.fetchEntry(accessToken: accessToken, entryId: entryId)
            guard let remoteStatus = EntryStatus(rawValue: remote.status), remoteStatus != .draft else {
                throw error
            }
            entry.status = remoteStatus
            store.save()
        }
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
        let fileSize = try artifactFileSize(artifact)
        let remoteArtifact = try await createOrReconcileArtifact(
            artifact,
            artifactId: artifactId,
            fileSize: fileSize,
            accessToken: accessToken
        )

        guard remoteArtifact.uploadState != UploadState.uploaded.rawValue else {
            markArtifactUploaded(artifact, from: remoteArtifact)
            return
        }

        try await uploadAndConfirmArtifact(artifact, artifactId: artifactId, accessToken: accessToken)
    }

    private func artifactFileSize(_ artifact: LocalArtifact) throws -> Int {
        guard FileManager.default.fileExists(atPath: artifact.localPath) else {
            throw SyncError.localFileNotFound("Local file not found for artifact \(artifact.id) at \(artifact.localPath)")
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: artifact.localPath)
            guard let size = attributes[.size] as? NSNumber else {
                throw SyncError.localFileMetadataUnavailable("Could not determine size for artifact \(artifact.id)")
            }
            return size.intValue
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.localFileMetadataUnavailable("Could not read local file metadata for artifact \(artifact.id): \(error.localizedDescription)")
        }
    }

    private func createOrReconcileArtifact(
        _ artifact: LocalArtifact,
        artifactId: String,
        fileSize: Int,
        accessToken: String
    ) async throws -> ArtifactResponse {
        do {
            return try await apiClient.createArtifact(
                accessToken: accessToken,
                entryId: artifact.entryId,
                artifact: artifact,
                sizeBytes: fileSize
            )
        } catch let error as APIError where error.error.code == "ID_CONFLICT" {
            let remoteEntry = try await apiClient.fetchEntry(accessToken: accessToken, entryId: artifact.entryId)
            guard let matchingArtifact = remoteEntry.artifacts?.first(where: { $0.id == artifactId }),
                  isExactArtifactRetry(remote: matchingArtifact, local: artifact, sizeBytes: fileSize) else {
                throw error
            }
            return matchingArtifact
        }
    }

    private func markArtifactUploaded(_ artifact: LocalArtifact, from remoteArtifact: ArtifactResponse) {
        artifact.uploadState = .uploaded
        artifact.syncPhase = .uploaded
        artifact.storageKey = remoteArtifact.storageKey
        artifact.remoteUrl = remoteArtifact.remoteUrl
        store.save()
    }

    private func uploadAndConfirmArtifact(
        _ artifact: LocalArtifact,
        artifactId: String,
        accessToken: String
    ) async throws {
        artifact.uploadState = .uploading
        artifact.syncPhase = .uploading
        store.save()

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

    private func isExactCreateRetry(remote: EntryResponse, local: LocalPracticeEntry) -> Bool {
        remote.courseId == local.courseId &&
            remote.studentId == local.studentId &&
            (remote.kind ?? EntryKind.practice.rawValue) == local.kind.rawValue &&
            abs(remote.practiceDate.timeIntervalSince(local.practiceDate)) < 0.001 &&
            remote.goalText == local.goalText &&
            remote.durationSeconds == local.durationSeconds &&
            remote.tags == local.tags &&
            remote.notes == local.notes &&
            (remote.consentConfirmedAt != nil) == (local.consentConfirmedAt != nil) &&
            remote.consentScope == local.consentScope?.rawValue &&
            remote.captureProfile == local.captureProfile?.rawValue
    }

    private func isExactArtifactRetry(
        remote: ArtifactResponse,
        local: LocalArtifact,
        sizeBytes: Int
    ) -> Bool {
        remote.entryId == local.entryId &&
            remote.type == local.type.rawValue &&
            remote.durationSeconds == local.durationSeconds &&
            remote.expectedSizeBytes == sizeBytes
    }

    private func executeSyncCaptureProfile(payload: [String: Any], accessToken: String) async throws {
        let entryId = payload["entryId"] as? String ?? ""
        let entry = try store.fetchEntry(id: entryId)
        let response = try await apiClient.updateEntryCaptureProfile(
            accessToken: accessToken,
            entryId: entryId,
            captureProfile: entry.captureProfile
        )
        entry.remoteUpdatedAt = response.updatedAt ?? Date()
        store.save()
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
