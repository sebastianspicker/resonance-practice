import Foundation
import SwiftData

// Applies remote course snapshots while preserving pending local entry work.

@MainActor
/// Applies remote-wins course snapshots while preserving entries with pending local commands.
final class EntryReconciliationService {
    private let modelContext: ModelContext
    private let apiClient: APIClient
    private let ownerId: String
    private let isCurrentProfile: () -> Bool

    init(
        modelContext: ModelContext,
        apiClient: APIClient,
        ownerId: String,
        isCurrentProfile: @escaping () -> Bool = { true }
    ) {
        self.modelContext = modelContext
        self.apiClient = apiClient
        self.ownerId = ownerId
        self.isCurrentProfile = isCurrentProfile
    }

    /// Reconciles one bounded cursor page at a time. A failed or cancelled traversal
    /// retains already-authoritative page updates but never performs stale cleanup.
    func refresh(courseId: String, accessToken: String) async throws {
        var remoteIds = Set<String>()
        var cursor: String?
        var seenCursors = Set<String>()

        while true {
            try Task.checkCancellation()
            try requireCurrentProfile()
            let page = try await apiClient.fetchEntries(
                accessToken: accessToken,
                courseId: courseId,
                cursor: cursor
            )
            try Task.checkCancellation()
            try requireCurrentProfile()

            let queuedEntryIds = try pendingEntryIds()
            let localByID = try localEntries(
                ids: page.items.map(\.id),
                courseId: courseId
            )
            for response in page.items {
                try Task.checkCancellation()
                remoteIds.insert(response.id)
                _ = upsert(
                    response,
                    existing: localByID[response.id],
                    preserveLocalChanges: queuedEntryIds.contains(response.id)
                )
            }
            try requireCurrentProfile()
            try modelContext.save()

            guard let nextCursor = page.nextCursor, !nextCursor.isEmpty else { break }
            guard seenCursors.insert(nextCursor).inserted else {
                throw SyncError.payloadParseError("Entry reconciliation received a repeated cursor")
            }
            cursor = nextCursor
        }

        try Task.checkCancellation()
        try requireCurrentProfile()
        try await removeStaleEntries(
            courseId: courseId,
            remoteIds: remoteIds
        )
    }

    private func upsert(
        _ response: EntryResponse,
        existing local: LocalPracticeEntry?,
        preserveLocalChanges: Bool
    ) -> LocalPracticeEntry {
        guard let local else {
            let details = PracticeEntryDetails(
                practiceDate: response.practiceDate,
                goalText: response.goalText,
                durationSeconds: response.durationSeconds,
                tags: response.tags,
                notes: response.notes
            )
            let context = CaptureContext(
                kind: EntryKind(rawValue: response.kind ?? "practice") ?? .practice,
                consentConfirmedAt: response.consentConfirmedAt,
                consentScope: response.consentScope.flatMap(ConsentScope.init(rawValue:)),
                captureProfile: response.captureProfile.flatMap(CaptureProfile.init(rawValue:))
            )
            let inserted = LocalPracticeEntry(
                id: response.id,
                courseId: response.courseId,
                studentId: response.studentId,
                details: details,
                status: EntryStatus(rawValue: response.status) ?? .draft,
                captureContext: context
            )
            let remoteDate = response.updatedAt ?? response.createdAt ?? Date()
            inserted.remoteUpdatedAt = remoteDate
            inserted.updatedAt = remoteDate
            inserted.serverVersion = response.version
            modelContext.insert(inserted)
            mergeArtifacts(response.artifacts ?? [], into: inserted)
            return inserted
        }
        merge(response, into: local, preserveLocalChanges: preserveLocalChanges)
        return local
    }

    private func requireCurrentProfile() throws {
        guard isCurrentProfile() else { throw CancellationError() }
    }

    private func localEntries(
        ids: [String],
        courseId: String
    ) throws -> [String: LocalPracticeEntry] {
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<LocalPracticeEntry>(
            predicate: #Predicate { $0.courseId == courseId && ids.contains($0.id) }
        )
        return Dictionary(uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.id, $0) })
    }

    private func removeStaleEntries(
        courseId: String,
        remoteIds: Set<String>
    ) async throws {
        var lastID: String?
        while true {
            try Task.checkCancellation()
            try requireCurrentProfile()
            let batch = try staleEntryBatch(courseId: courseId, afterID: lastID)
            guard !batch.isEmpty else { return }
            let queuedEntryIds = try pendingEntryIds()
            for local in batch where !remoteIds.contains(local.id) && !queuedEntryIds.contains(local.id) {
                modelContext.delete(local)
            }
            try requireCurrentProfile()
            try modelContext.save()
            lastID = batch.last?.id
            await Task.yield()
        }
    }

    private func staleEntryBatch(
        courseId: String,
        afterID: String?
    ) throws -> [LocalPracticeEntry] {
        var descriptor: FetchDescriptor<LocalPracticeEntry>
        if let afterID {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.courseId == courseId && $0.remoteUpdatedAt != nil && $0.id > afterID
                }
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.courseId == courseId && $0.remoteUpdatedAt != nil }
            )
        }
        descriptor.sortBy = [SortDescriptor(\.id, order: .forward)]
        descriptor.fetchLimit = 50
        return try modelContext.fetch(descriptor)
    }

    private func merge(
        _ response: EntryResponse,
        into local: LocalPracticeEntry,
        preserveLocalChanges: Bool
    ) {
        let remoteDate = response.updatedAt ?? response.createdAt ?? Date()
        if preserveLocalChanges || local.remoteUpdatedAt.map({ local.updatedAt > $0 }) == true {
            local.status = EntryStatus(rawValue: response.status) ?? local.status
            local.remoteUpdatedAt = remoteDate
            local.serverVersion = response.version
            mergeArtifacts(response.artifacts ?? [], into: local)
            return
        }
        local.studentId = response.studentId
        local.kind = EntryKind(rawValue: response.kind ?? "practice") ?? .practice
        local.practiceDate = response.practiceDate
        local.goalText = response.goalText
        local.durationSeconds = response.durationSeconds
        local.tags = response.tags
        local.notes = response.notes
        local.status = EntryStatus(rawValue: response.status) ?? .draft
        local.consentConfirmedAt = response.consentConfirmedAt
        local.consentScope = response.consentScope.flatMap(ConsentScope.init(rawValue:))
        local.captureProfile = response.captureProfile.flatMap(CaptureProfile.init(rawValue:))
        local.remoteUpdatedAt = remoteDate
        local.updatedAt = remoteDate
        local.serverVersion = response.version
        mergeArtifacts(response.artifacts ?? [], into: local)
    }

    private func mergeArtifacts(_ responses: [ArtifactResponse], into entry: LocalPracticeEntry) {
        let localById = Dictionary(uniqueKeysWithValues: entry.artifacts.map { ($0.id, $0) })
        for response in responses {
            if let local = localById[response.id] {
                local.durationSeconds = response.durationSeconds
                local.uploadState = UploadState(rawValue: response.uploadState) ?? local.uploadState
            } else {
                let artifact = LocalArtifact(
                    id: response.id,
                    entryId: entry.id,
                    type: ArtifactType(rawValue: response.type) ?? .audio,
                    durationSeconds: response.durationSeconds,
                    localPath: ""
                )
                artifact.uploadState = UploadState(rawValue: response.uploadState) ?? .uploaded
                artifact.syncPhase = artifact.uploadState == .uploaded ? .uploaded : .queued
                entry.artifacts.append(artifact)
                modelContext.insert(artifact)
            }
        }
    }

    /// Reads owner-scoped work in bounded keyset batches. A read or payload
    /// failure stops reconciliation rather than risking a pending local edit.
    private func pendingEntryIds() throws -> Set<String> {
        guard !ownerId.isEmpty else {
            throw SyncError.payloadParseError("Entry reconciliation has no local owner")
        }
        var entryIDs = Set<String>()
        var lastID: String?

        while true {
            try Task.checkCancellation()
            try requireCurrentProfile()
            let batch = try queuedWorkBatch(afterID: lastID)
            guard !batch.isEmpty else { return entryIDs }
            for item in batch {
                guard let taskType = item.taskType else {
                    throw SyncError.unknownTaskType(item.type)
                }
                let decoded = try OutboxEnvelope.decode(
                    payloadJSON: item.payloadJSON,
                    taskType: taskType
                )
                if decoded.migrated {
                    item.payloadJSON = try decoded.envelope.encodedJSON()
                }
                if let entryID = decoded.envelope.payload.entryID {
                    entryIDs.insert(entryID)
                }
            }
            lastID = batch.last?.id
        }
    }

    private func queuedWorkBatch(afterID: String?) throws -> [SyncQueueItem] {
        let ownerId = self.ownerId
        var descriptor: FetchDescriptor<SyncQueueItem>
        if let afterID {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.ownerId == ownerId && $0.id > afterID }
            )
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.ownerId == ownerId })
        }
        descriptor.sortBy = [SortDescriptor(\.id, order: .forward)]
        descriptor.fetchLimit = 50
        return try modelContext.fetch(descriptor)
    }
}
