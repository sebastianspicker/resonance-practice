import Foundation
import SwiftData

// Builds durable command payloads and applies authoritative command outcomes.

extension TaskExecutor {
    /// Returns the command-endpoint representation for work that does not
    /// require a separate media upload session. Artifact uploads deliberately
    /// stay outside this batch because their presigned PUT has different retry
    /// and completion semantics.
    func command(for item: SyncQueueItem) throws -> SyncCommand? {
        let (taskType, payload) = try taskTypeAndPayload(for: item)

        switch taskType {
        case .syncArtifact: return nil
        case .createEntry: return try createEntryCommand(item: item, payload: payload)
        case .updateEntry, .syncCaptureProfile: return try updateEntryCommand(item: item, payload: payload)
        case .syncCaptureMarkers: return try captureMarkersCommand(item: item, payload: payload)
        case .submitEntry: return try submitEntryCommand(item: item, payload: payload)
        case .deleteEntry: return try deleteEntryCommand(item: item, payload: payload)
        case .postFeedback: return try feedbackCommand(item: item, payload: payload)
        }
    }

    func taskTypeAndPayload(for item: SyncQueueItem) throws -> (SyncTaskType, [String: Any]) {
        guard let taskType = item.taskType else {
            throw SyncError.unknownTaskType("Unknown sync task type: \(item.type)")
        }
        guard let data = item.payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SyncError.payloadParseError("Failed to parse payload as JSON dictionary")
        }
        return (taskType, payload)
    }

    private func createEntryCommand(item: SyncQueueItem, payload: [String: Any]) throws -> SyncCommand {
        let entry = try entry(forPayload: payload)
        return makeCommand(item: item, entityID: entry.id, kind: .createEntry, payload: entryPayload(entry))
    }

    private func updateEntryCommand(item: SyncQueueItem, payload: [String: Any]) throws -> SyncCommand {
        let entry = try entry(forPayload: payload)
        return makeCommand(
            item: item,
            entityID: entry.id,
            kind: .updateEntry,
            baseVersion: try baseVersion(for: entry),
            payload: entryPayload(entry)
        )
    }

    private func captureMarkersCommand(item: SyncQueueItem, payload: [String: Any]) throws -> SyncCommand {
        let entry = try store.fetchEntry(id: requiredEntryID(payload))
        let markers = try store.fetchCaptureMarkers(entryId: entry.id).map(markerPayload)
        return SyncCommand(
            operationId: item.id,
            entityId: entry.id,
            kind: .replaceCaptureMarkers,
            baseVersion: try baseVersion(for: entry),
            payload: .object(["markers": .array(markers)])
        )
    }

    private func submitEntryCommand(item: SyncQueueItem, payload: [String: Any]) throws -> SyncCommand {
        let entry = try entry(forPayload: payload)
        return makeCommand(item: item, entityID: entry.id, kind: .submitEntry, baseVersion: try baseVersion(for: entry))
    }

    private func makeCommand(
        item: SyncQueueItem,
        entityID: String,
        kind: SyncCommandKind,
        baseVersion: Int? = nil,
        payload: JSONValue = .object([:])
    ) -> SyncCommand {
        SyncCommand(
            operationId: item.id,
            entityId: entityID,
            kind: kind,
            baseVersion: baseVersion,
            payload: payload
        )
    }

    private func deleteEntryCommand(item: SyncQueueItem, payload: [String: Any]) throws -> SyncCommand {
        let entryID = try requiredEntryID(payload)
        guard let baseVersion = payload["baseVersion"] as? Int else {
            throw SyncError.missingServerVersion(entryID)
        }
        return SyncCommand(
            operationId: item.id,
            entityId: entryID,
            kind: .deleteEntry,
            baseVersion: baseVersion
        )
    }

    func entry(forPayload payload: [String: Any]) throws -> LocalPracticeEntry {
        try store.fetchEntry(id: requiredEntryID(payload))
    }

    private func feedbackCommand(item: SyncQueueItem, payload: [String: Any]) throws -> SyncCommand {
        let feedbackID = payload["feedbackId"] as? String ?? ""
        let feedback = try store.fetchFirst(
            FetchDescriptor<LocalFeedback>(predicate: #Predicate { $0.id == feedbackID })
        )
        let entry = try entryForFeedback(feedback)
        return SyncCommand(
            operationId: item.id,
            entityId: feedback.id,
            kind: .createFeedback,
            baseVersion: try baseVersion(for: entry),
            payload: feedbackPayload(feedback)
        )
    }

    func commandEntityID(for item: SyncQueueItem) throws -> String? {
        let (taskType, payload) = try taskTypeAndPayload(for: item)
        if taskType == .syncArtifact {
            guard let artifactID = payload["artifactId"] as? String, !artifactID.isEmpty else {
                throw SyncError.payloadParseError("Sync payload is missing artifactId")
            }
            return try store.fetchArtifact(id: artifactID).entryId
        }
        if taskType == .postFeedback {
            guard let feedbackID = payload["feedbackId"] as? String, !feedbackID.isEmpty else {
                throw SyncError.payloadParseError("Sync payload is missing feedbackId")
            }
            let feedback = try store.fetchFirst(
                FetchDescriptor<LocalFeedback>(predicate: #Predicate { $0.id == feedbackID })
            )
            return try entryForFeedback(feedback).id
        }
        return payload["entryId"] as? String
    }

    /// Applies an outcome only when it belongs to the local operation that requested it.
    func apply(_ result: SyncCommandResult, for item: SyncQueueItem) throws {
        guard result.operationId == item.id else {
            throw SyncError.payloadParseError("Command response did not match local operation \(item.id)")
        }
        switch result.status {
        case .applied, .duplicate:
            if let resource = result.resource {
                apply(resource, currentVersion: result.currentVersion)
            } else if let entry = try? store.fetchEntry(id: result.entityId) {
                entry.serverVersion = result.currentVersion ?? entry.serverVersion
                if result.kind == .submitEntry { entry.status = .submitted }
                store.save()
            }
        case .conflict:
            let localEntityID = (try? commandEntityID(for: item)) ?? result.entityId
            throw SyncError.serverConflict(
                entityId: result.resource?.id ?? localEntityID,
                currentVersion: result.currentVersion
            )
        case .rejected:
            throw SyncError.commandRejected(result.code ?? result.message ?? "Command rejected")
        case .retryable:
            throw SyncError.commandRetryable(result.code ?? result.message ?? "Command retryable")
        }
    }

    private func requiredEntryID(_ payload: [String: Any]) throws -> String {
        guard let entryID = payload["entryId"] as? String, !entryID.isEmpty else {
            throw SyncError.payloadParseError("Sync payload is missing entryId")
        }
        return entryID
    }

    /// Rejects mutations for entries that have never received an authoritative server version.
    func baseVersion(for entry: LocalPracticeEntry) throws -> Int {
        guard let version = entry.serverVersion else {
            throw SyncError.missingServerVersion(entry.id)
        }
        return version
    }

    private func entryPayload(_ entry: LocalPracticeEntry) -> JSONValue {
        var values: [String: JSONValue] = [
            "courseId": .string(entry.courseId),
            "kind": .string(entry.kind.rawValue),
            "practiceDate": .string(JSONEncoder.apiEncoderDateString(entry.practiceDate)),
            "goalText": .string(entry.goalText),
            "tags": .array(entry.tags.map(JSONValue.string)),
            "consentConfirmedAt": entry.consentConfirmedAt.map { .string(JSONEncoder.apiEncoderDateString($0)) } ?? .null,
            "consentScope": entry.consentScope.map { .string($0.rawValue) } ?? .null,
            "captureProfile": entry.captureProfile.map { .string($0.rawValue) } ?? .null
        ]
        values["durationSeconds"] = entry.durationSeconds.map(JSONValue.integer) ?? .null
        values["notes"] = entry.notes.map(JSONValue.string) ?? .null
        return .object(values)
    }

    private func markerPayload(_ marker: LocalCaptureMarker) -> JSONValue {
        .object([
            "id": .string(marker.id),
            "artifactId": .string(marker.artifactId),
            "timeSeconds": .integer(marker.timeSeconds),
            "kind": .string(marker.kind.rawValue),
            "note": marker.note.map(JSONValue.string) ?? .null
        ])
    }

    private func feedbackPayload(_ feedback: LocalFeedback) -> JSONValue {
        .object([
            "targetType": .string(feedback.targetType),
            "targetId": .string(feedback.targetId),
            "status": .string(feedback.status.rawValue),
            "commentsText": .string(feedback.commentsText),
            "markers": .array(feedback.chronologicallyOrderedMarkers.map {
                .object(["id": .string($0.id), "timeSeconds": .integer($0.timeSeconds), "text": .string($0.text)])
            })
        ])
    }

    private func entryForFeedback(_ feedback: LocalFeedback) throws -> LocalPracticeEntry {
        if feedback.targetType == "entry" { return try store.fetchEntry(id: feedback.targetId) }

        let artifact = try store.fetchArtifact(id: feedback.targetId)
        return try store.fetchEntry(id: artifact.entryId)
    }

    private func apply(_ response: EntryResponse, currentVersion: Int?) {
        guard let entry = try? store.fetchEntry(id: response.id) else { return }
        entry.status = EntryStatus(rawValue: response.status) ?? entry.status
        entry.serverVersion = currentVersion ?? response.version ?? entry.serverVersion
        entry.remoteUpdatedAt = response.updatedAt ?? response.createdAt ?? Date()
        store.save()
    }
}
