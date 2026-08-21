import Foundation
import SwiftData

// Materializes a decoded fixture while preserving the local offline queue payload contract.
@MainActor
struct DemoDataLoader {
    let modelContext: ModelContext

    func load(_ fixture: DemoFixture, roleInCourse: String) throws {
        let usersById = Dictionary(uniqueKeysWithValues: fixture.users.map { ($0.id, $0) })

        loadCourses(fixture.courses, roleInCourse: roleInCourse)
        let entriesById = loadEntries(fixture.entries)
        let artifactToEntry = loadArtifacts(fixture.artifacts, entriesById: entriesById)
        loadFeedback(fixture.feedback, usersById: usersById, entriesById: entriesById, artifactToEntry: artifactToEntry)
        try loadQueue(fixture.syncQueue)
        try modelContext.save()
    }

    private func loadCourses(_ courses: [DemoCourse], roleInCourse: String) {
        for course in courses {
            modelContext.insert(LocalCourse(id: course.id, title: course.title, roleInCourse: roleInCourse))
        }
    }

    private func loadEntries(_ entries: [DemoEntry]) -> [String: LocalPracticeEntry] {
        var entriesById: [String: LocalPracticeEntry] = [:]
        for entry in entries {
            let localEntry = LocalPracticeEntry(
                id: entry.id,
                courseId: entry.courseId,
                studentId: entry.studentId,
                details: PracticeEntryDetails(
                    practiceDate: entry.practiceDate,
                    goalText: entry.goalText,
                    durationSeconds: entry.durationSeconds,
                    tags: entry.tags,
                    notes: entry.notes
                ),
                status: EntryStatus(rawValue: entry.status) ?? .draft,
                captureContext: CaptureContext(
                    kind: EntryKind(rawValue: entry.kind ?? EntryKind.practice.rawValue) ?? .practice,
                    consentConfirmedAt: entry.consentConfirmedAt,
                    consentScope: entry.consentScope.flatMap(ConsentScope.init(rawValue:)),
                    captureProfile: entry.captureProfile.flatMap(CaptureProfile.init(rawValue:))
                )
            )
            localEntry.updatedAt = entry.createdAt
            modelContext.insert(localEntry)
            entriesById[entry.id] = localEntry
        }
        return entriesById
    }

    private func loadArtifacts(_ artifacts: [DemoArtifact], entriesById: [String: LocalPracticeEntry]) -> [String: String] {
        var artifactToEntry: [String: String] = [:]
        for artifact in artifacts {
            guard let localEntry = entriesById[artifact.entryId] else { continue }
            let localArtifact = LocalArtifact(
                id: artifact.id,
                entryId: artifact.entryId,
                type: ArtifactType(rawValue: artifact.type) ?? .audio,
                durationSeconds: artifact.durationSeconds,
                localPath: artifact.localPath
            )
            localArtifact.createdAt = artifact.createdAt
            localArtifact.uploadState = UploadState(rawValue: artifact.uploadState) ?? .pending
            localArtifact.syncPhase = ArtifactSyncPhase(rawValue: artifact.syncPhase) ?? .queued
            localArtifact.storageKey = artifact.storageKey
            localArtifact.remoteUrl = artifact.remoteUrl
            localEntry.artifacts.append(localArtifact)
            modelContext.insert(localArtifact)
            artifactToEntry[artifact.id] = artifact.entryId
        }
        return artifactToEntry
    }

    private func loadFeedback(
        _ feedbackItems: [DemoFeedback],
        usersById: [String: DemoUser],
        entriesById: [String: LocalPracticeEntry],
        artifactToEntry: [String: String]
    ) {
        for feedback in feedbackItems {
            let teacherName = usersById[feedback.teacherId]?.displayName ?? "Mock Teacher"
            let localFeedback = LocalFeedback(
                id: feedback.id,
                targetType: feedback.targetType,
                targetId: feedback.targetId,
                teacherName: teacherName,
                status: FeedbackStatus(rawValue: feedback.status) ?? .accepted,
                commentsText: feedback.commentsText
            )
            localFeedback.createdAt = feedback.createdAt

            for marker in feedback.markers {
                let localMarker = LocalMarker(id: marker.id, timeSeconds: marker.timeSeconds, text: marker.text)
                localFeedback.markers.append(localMarker)
                modelContext.insert(localMarker)
            }

            if feedback.targetType == "entry", let entry = entriesById[feedback.targetId] {
                entry.feedback.append(localFeedback)
            } else if feedback.targetType == "artifact",
                      let entryId = artifactToEntry[feedback.targetId],
                      let entry = entriesById[entryId] {
                entry.feedback.append(localFeedback)
            }

            modelContext.insert(localFeedback)
        }
    }

    private func loadQueue(_ queue: [DemoQueueItem]?) throws {
        for item in queue ?? [] {
            let payloadData = try JSONSerialization.data(withJSONObject: item.payload)
            guard let payloadJSON = String(data: payloadData, encoding: .utf8) else { continue }
            let queueItem = SyncQueueItem(
                id: item.id,
                type: item.type,
                payloadJSON: payloadJSON,
                ownerId: "demo"
            )
            queueItem.status = item.status
            queueItem.retryCount = item.retryCount
            queueItem.lastError = item.lastError
            queueItem.createdAt = item.createdAt
            queueItem.nextAttemptAt = item.nextAttemptAt
            modelContext.insert(queueItem)
        }
    }
}
