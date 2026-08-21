import Foundation
import SwiftData

// Applies remote course snapshots while preserving pending local entry work.

@MainActor
/// Applies remote-wins course snapshots while preserving entries with pending local commands.
final class EntryReconciliationService {
    private let modelContext: ModelContext
    private let apiClient: APIClient

    init(modelContext: ModelContext, apiClient: APIClient) {
        self.modelContext = modelContext
        self.apiClient = apiClient
    }

    /// Fetches all cursor pages, upserts authoritative rows, and removes only safe stale rows.
    func refresh(courseId: String, accessToken: String) async throws {
        let responses = try await fetchAllEntries(courseId: courseId, accessToken: accessToken)
        let localEntries = try modelContext.fetch(
            FetchDescriptor<LocalPracticeEntry>(predicate: #Predicate { $0.courseId == courseId })
        )
        let localById = Dictionary(uniqueKeysWithValues: localEntries.map { ($0.id, $0) })
        let remoteIds = Set(responses.map(\.id))
        let queuedEntryIds = pendingEntryIds()

        for response in responses {
            upsert(
                response,
                existing: localById[response.id],
                preserveLocalChanges: queuedEntryIds.contains(response.id)
            )
        }

        for local in localEntries where local.remoteUpdatedAt != nil &&
            !remoteIds.contains(local.id) && !queuedEntryIds.contains(local.id) {
            modelContext.delete(local)
        }
        try modelContext.save()
    }

    private func fetchAllEntries(courseId: String, accessToken: String) async throws -> [EntryResponse] {
        var responses: [EntryResponse] = []
        var cursor: String?
        var seen = Set<String>()

        repeat {
            let page = try await apiClient.fetchEntries(
                accessToken: accessToken,
                courseId: courseId,
                cursor: cursor
            )
            responses.append(contentsOf: page.items)
            guard let next = page.nextCursor, !next.isEmpty, seen.insert(next).inserted else {
                cursor = nil
                break
            }
            cursor = next
        } while cursor != nil

        return responses
    }

    private func upsert(
        _ response: EntryResponse,
        existing local: LocalPracticeEntry?,
        preserveLocalChanges: Bool
    ) {
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
            return
        }
        merge(response, into: local, preserveLocalChanges: preserveLocalChanges)
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
                local.storageKey = response.storageKey
                local.remoteUrl = response.remoteUrl
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
                artifact.storageKey = response.storageKey
                artifact.remoteUrl = response.remoteUrl
                entry.artifacts.append(artifact)
                modelContext.insert(artifact)
            }
        }
    }

    private func pendingEntryIds() -> Set<String> {
        let queue = (try? modelContext.fetch(FetchDescriptor<SyncQueueItem>())) ?? []
        return Set(queue.compactMap { item in
            guard let data = item.payloadJSON.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return payload["entryId"] as? String
        })
    }
}
