import Foundation
import SwiftData

// Executes queued API commands and applies their authoritative server results to local records.

extension TaskExecutor {
    // MARK: - Private helpers

    /// Keeps artifact uploads on their dedicated handshake while routing other task-specific work.
    func execute(
        taskType: SyncTaskType,
        item: SyncQueueItem,
        payload: [String: Any],
        accessToken: String
    ) async throws {
        switch taskType {
        case .createEntry: try await executeCreateEntry(payload: payload, accessToken: accessToken)
        case .updateEntry: try await executeUpdateEntry(payload: payload, accessToken: accessToken)
        case .submitEntry: try await executeSubmitEntry(payload: payload, accessToken: accessToken)
        case .deleteEntry: try await executeDeleteEntry(payload: payload, accessToken: accessToken)
        case .syncArtifact:
            try await executeSyncArtifact(
                item: item,
                payload: payload,
                accessToken: accessToken
            )
        case .syncCaptureProfile: try await executeSyncCaptureProfile(payload: payload, accessToken: accessToken)
        case .syncCaptureMarkers: try await executeSyncCaptureMarkers(payload: payload, accessToken: accessToken)
        case .postFeedback: try await executePostFeedback(payload: payload, accessToken: accessToken)
        }
    }

    private func executeCreateEntry(payload: [String: Any], accessToken: String) async throws {
        let entryId = payload["entryId"] as? String ?? ""
        let entry = try entry(forPayload: payload)
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
        entry.serverVersion = response.version
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

    private func executeSyncArtifact(
        item: SyncQueueItem,
        payload: [String: Any],
        accessToken: String
    ) async throws {
        let artifactId = payload["artifactId"] as? String ?? ""
        let artifact = try store.fetchArtifact(id: artifactId)
        let entry = try store.fetchEntry(id: artifact.entryId)
        let fileSize = try artifactFileSize(artifact)
        let sessionBaseVersion = try artifactSessionBaseVersion(
            item: item,
            payload: payload,
            entry: entry
        )
        let session = try await apiClient.createArtifactSession(
            accessToken: accessToken,
            request: ArtifactSessionRequest(
                operationId: item.id,
                entryId: entry.id,
                artifact: artifact,
                sizeBytes: fileSize,
                baseVersion: sessionBaseVersion
            )
        )
        try Task.checkCancellation()
        entry.serverVersion = session.currentVersion

        guard session.completed != true,
              session.artifact.uploadState != UploadState.uploaded.rawValue else {
            markArtifactUploaded(artifact, from: session.artifact)
            return
        }

        guard let uploadURLString = session.uploadUrl,
              let uploadURL = URL(string: uploadURLString),
              uploadURL.scheme != nil else {
            throw SyncError.invalidPresignUrl("Invalid presign URL for artifact \(artifactId)")
        }

        artifact.uploadState = .uploading
        artifact.syncPhase = .uploading
        artifact.storageKey = session.artifact.storageKey
        store.save()

        try await uploadFile(
            url: uploadURL,
            fileURL: URL(fileURLWithPath: artifact.localPath),
            requiredHeaders: session.requiredHeaders ?? [:]
        )
        try Task.checkCancellation()
        artifact.syncPhase = .confirming
        store.save()

        let completion = try await apiClient.completeArtifactSession(
            accessToken: accessToken,
            sessionId: session.sessionId
        )
        try Task.checkCancellation()
        entry.serverVersion = completion.currentVersion
        markArtifactUploaded(artifact, from: completion.artifact)
    }

    private func artifactSessionBaseVersion(
        item: SyncQueueItem,
        payload: [String: Any],
        entry: LocalPracticeEntry
    ) throws -> Int {
        if let persistedVersion = payload["baseVersion"] as? Int {
            return persistedVersion
        }
        let initialVersion = try baseVersion(for: entry)
        var persistedPayload = payload
        persistedPayload["baseVersion"] = initialVersion
        guard JSONSerialization.isValidJSONObject(persistedPayload) else {
            throw SyncError.payloadParseError("Artifact sync payload is not valid JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: persistedPayload, options: [])
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw SyncError.payloadParseError("Artifact sync payload is not valid UTF-8")
        }
        item.payloadJSON = payloadJSON
        store.save()
        return initialVersion
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
            throw SyncError.localFileMetadataUnavailable(
                "Could not read local file metadata for artifact \(artifact.id): \(error.localizedDescription)"
            )
        }
    }

    private func markArtifactUploaded(_ artifact: LocalArtifact, from remoteArtifact: ArtifactResponse) {
        artifact.uploadState = .uploaded
        artifact.syncPhase = .uploaded
        artifact.storageKey = remoteArtifact.storageKey
        artifact.remoteUrl = remoteArtifact.remoteUrl
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

    private func executeSyncCaptureProfile(payload: [String: Any], accessToken: String) async throws {
        let entryId = payload["entryId"] as? String ?? ""
        let entry = try entry(forPayload: payload)
        let response = try await apiClient.updateEntryCaptureProfile(
            accessToken: accessToken,
            entryId: entryId,
            captureProfile: entry.captureProfile
        )
        entry.remoteUpdatedAt = response.updatedAt ?? Date()
        entry.serverVersion = response.version
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
