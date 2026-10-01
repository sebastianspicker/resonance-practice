import Foundation

// Executes queued API commands and applies their authoritative server results to local records.

extension TaskExecutor {
    /// Executes the dedicated artifact-session path. All entry and feedback
    /// mutations are sent through the typed v1 command batch endpoint.
    func execute(item: SyncQueueItem, accessToken: String) async throws {
        let (taskType, payload) = try taskTypeAndPayload(for: item)
        guard taskType == .syncArtifact else {
            throw SyncError.payloadParseError("Non-artifact work must be sent through sync commands")
        }
        try await executeSyncArtifact(item: item, payload: payload, accessToken: accessToken)
    }

    private func executeSyncArtifact(
        item: SyncQueueItem,
        payload: OutboxPayload,
        accessToken: String
    ) async throws {
        guard let artifactId = payload.artifactID, !artifactId.isEmpty else {
            throw SyncError.payloadParseError("Sync payload is missing artifactId")
        }
        let artifact = try store.fetchArtifact(id: artifactId)
        let entry = try store.fetchEntry(id: artifact.entryId)
        let localFileURL = try FileStore.containedMediaURL(atPath: artifact.localPath)
        let filePreparation = try await prepareArtifactFile(artifactId: artifact.id, at: localFileURL)
        try Task.checkCancellation()
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
                sizeBytes: filePreparation.sizeBytes,
                checksumSha256: filePreparation.checksumSha256,
                baseVersion: sessionBaseVersion
            )
        )
        try Task.checkCancellation()
        entry.serverVersion = session.currentVersion

        guard session.completed != true,
              session.artifact.uploadState != UploadState.uploaded.rawValue else {
            markArtifactUploaded(artifact)
            return
        }

        guard let uploadURLString = session.uploadUrl,
              let uploadURL = URL(string: uploadURLString),
              uploadURL.scheme != nil else {
            throw SyncError.invalidPresignUrl("Invalid presign URL for artifact \(artifactId)")
        }

        artifact.uploadState = .uploading
        artifact.syncPhase = .uploading
        store.save()

        try await uploadFile(
            url: uploadURL,
            fileURL: localFileURL,
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
        markArtifactUploaded(artifact)
    }

    private func artifactSessionBaseVersion(
        item: SyncQueueItem,
        payload: OutboxPayload,
        entry: LocalPracticeEntry
    ) throws -> Int {
        if case let .artifact(artifactPayload) = payload, let persistedVersion = artifactPayload.baseVersion {
            return persistedVersion
        }
        let initialVersion = try baseVersion(for: entry)
        guard case var .artifact(artifactPayload) = payload else {
            throw SyncError.payloadParseError("Artifact sync payload is incompatible with its task")
        }
        artifactPayload.baseVersion = initialVersion
        item.payloadJSON = try OutboxEnvelope(taskType: .syncArtifact, payload: .artifact(artifactPayload)).encodedJSON()
        store.save()
        return initialVersion
    }

    private func prepareArtifactFile(
        artifactId: String,
        at localFileURL: URL
    ) async throws -> MediaChecksum.FilePreparation {
        do {
            return try await MediaChecksum.prepare(for: localFileURL)
        } catch let error as SyncError {
            throw error
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            throw SyncError.localFileNotFound("Local file not found for artifact \(artifactId)")
        } catch {
            throw SyncError.localFileMetadataUnavailable(
                "Could not prepare local file for artifact \(artifactId): \(error.localizedDescription)"
            )
        }
    }

    private func markArtifactUploaded(_ artifact: LocalArtifact) {
        artifact.uploadState = .uploaded
        artifact.syncPhase = .uploaded
        store.save()
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
