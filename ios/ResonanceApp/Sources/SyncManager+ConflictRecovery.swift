import Foundation
import SwiftData

// Reconciles conflict resolution actions initiated from entry detail flows.

@MainActor
extension SyncManager {
    func reloadServerCopy(of entry: LocalPracticeEntry) async throws {
        guard let accessToken = authManager.session?.accessToken else { return }
        let response = try await apiClient.fetchEntry(accessToken: accessToken, entryId: entry.id)
        entry.kind = EntryKind(rawValue: response.kind ?? "") ?? entry.kind
        entry.practiceDate = response.practiceDate
        entry.goalText = response.goalText
        entry.durationSeconds = response.durationSeconds
        entry.tags = response.tags
        entry.notes = response.notes
        entry.status = EntryStatus(rawValue: response.status) ?? entry.status
        entry.consentConfirmedAt = response.consentConfirmedAt
        entry.consentScope = response.consentScope.flatMap(ConsentScope.init(rawValue:))
        entry.captureProfile = response.captureProfile.flatMap(CaptureProfile.init(rawValue:))
        entry.remoteUpdatedAt = response.updatedAt ?? response.createdAt ?? Date()
        entry.updatedAt = entry.remoteUpdatedAt ?? Date()
        entry.serverVersion = response.version
        store.discardWork(forEntryID: entry.id)
        conflictedEntryIDs.remove(entry.id)
        store.save()
        updateQueueMetrics()
    }

    @discardableResult
    func duplicateAsNewDraft(_ entry: LocalPracticeEntry, modelContext: ModelContext) throws -> LocalPracticeEntry {
        let copy = LocalPracticeEntry(
            id: UUID().uuidString,
            courseId: entry.courseId,
            studentId: entry.studentId,
            details: PracticeEntryDetails(
                practiceDate: entry.practiceDate,
                goalText: entry.goalText,
                durationSeconds: entry.durationSeconds,
                tags: entry.tags,
                notes: entry.notes
            ),
            status: .draft,
            captureContext: CaptureContext(
                kind: entry.kind,
                consentConfirmedAt: entry.consentConfirmedAt,
                consentScope: entry.consentScope,
                captureProfile: entry.captureProfile
            )
        )
        modelContext.insert(copy)
        try modelContext.save()
        enqueue(type: .createEntry, payload: ["entryId": copy.id])
        return copy
    }
}
