import Foundation
import SwiftData

@MainActor
final class DemoDataManager {
    private let modelContext: ModelContext
    private let demoPrefix = "demo_"

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadMockUniversityData(roleInCourse: String = "student") throws {
        let fixture = try loadFixture()
        try clearMockUniversityData()

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

    private func loadFeedback(_ feedbackItems: [DemoFeedback], usersById: [String: DemoUser], entriesById: [String: LocalPracticeEntry], artifactToEntry: [String: String]) {
        for feedback in feedbackItems {
            let teacherName = usersById[feedback.teacherId]?.displayName ?? "Mock Teacher"
            let localFeedback = LocalFeedback(
                id: feedback.id,
                targetType: feedback.targetType,
                targetId: feedback.targetId,
                teacherName: teacherName,
                status: FeedbackStatus(rawValue: feedback.status) ?? .ok,
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
            let queueItem = SyncQueueItem(id: item.id, type: item.type, payloadJSON: payloadJSON)
            queueItem.status = item.status
            queueItem.retryCount = item.retryCount
            queueItem.lastError = item.lastError
            queueItem.createdAt = item.createdAt
            queueItem.nextAttemptAt = item.nextAttemptAt
            modelContext.insert(queueItem)
        }
    }

    func clearMockUniversityData() throws {
        let courses = try modelContext.fetch(FetchDescriptor<LocalCourse>())
        let entries = try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>())
        let artifacts = try modelContext.fetch(FetchDescriptor<LocalArtifact>())
        let feedback = try modelContext.fetch(FetchDescriptor<LocalFeedback>())
        let markers = try modelContext.fetch(FetchDescriptor<LocalMarker>())
        let captureMarkers = try modelContext.fetch(FetchDescriptor<LocalCaptureMarker>())
        let queueItems = try modelContext.fetch(FetchDescriptor<SyncQueueItem>())

        let demoCourses = courses.filter { $0.id.hasPrefix(demoPrefix) }
        let demoEntries = entries.filter { $0.id.hasPrefix(demoPrefix) || $0.courseId.hasPrefix(demoPrefix) }
        let demoEntryIDs = Set(demoEntries.map(\.id))
        let demoArtifacts = artifacts.filter {
            $0.id.hasPrefix(demoPrefix) || $0.entryId.hasPrefix(demoPrefix) || demoEntryIDs.contains($0.entryId)
        }
        let demoArtifactIDs = Set(demoArtifacts.map(\.id))
        let demoFeedback = feedback.filter {
            $0.id.hasPrefix(demoPrefix) || $0.targetId.hasPrefix(demoPrefix) || demoEntryIDs.contains($0.targetId) || demoArtifactIDs.contains($0.targetId)
        }
        let demoCaptureMarkers = captureMarkers.filter {
            $0.id.hasPrefix(demoPrefix) || demoEntryIDs.contains($0.entryId) || demoArtifactIDs.contains($0.artifactId)
        }
        let demoQueueItems = queueItems.filter { isDemoQueueItem($0) }

        // Artifact rows do not delete their files automatically. Remove media
        // before SwiftData records so demo cleanup leaves no local evidence.
        for artifact in demoArtifacts where !artifact.localPath.isEmpty {
            FileStore.deleteFileIfExists(atPath: artifact.localPath)
        }

        demoCourses.forEach(modelContext.delete)
        demoEntries.forEach(modelContext.delete)
        demoArtifacts.forEach(modelContext.delete)
        demoFeedback.forEach(modelContext.delete)
        markers.filter { $0.id.hasPrefix(demoPrefix) }.forEach(modelContext.delete)
        demoCaptureMarkers.forEach(modelContext.delete)
        demoQueueItems.forEach(modelContext.delete)

        try modelContext.save()
    }

    private func isDemoQueueItem(_ item: SyncQueueItem) -> Bool {
        guard let data = item.payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return item.id.hasPrefix(demoPrefix)
        }
        let referencedIDs = ["entryId", "artifactId", "feedbackId", "targetId"]
        return item.id.hasPrefix(demoPrefix) || referencedIDs.contains {
            (payload[$0] as? String)?.hasPrefix(demoPrefix) == true
        }
    }

    private func loadFixture() throws -> DemoFixture {
        guard let url = Bundle.main.url(forResource: "mock-university", withExtension: "json") else {
            throw DemoDataError.fixtureNotFound
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: value) { return date }
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        return try decoder.decode(DemoFixture.self, from: data)
    }
}

enum DemoDataError: LocalizedError {
    case fixtureNotFound

    var errorDescription: String? {
        switch self {
        case .fixtureNotFound:
            return "mock-university.json not found in app bundle."
        }
    }
}

private struct DemoFixture: Decodable {
    let users: [DemoUser]
    let courses: [DemoCourse]
    let memberships: [DemoMembership]
    let entries: [DemoEntry]
    let artifacts: [DemoArtifact]
    let feedback: [DemoFeedback]
    let syncQueue: [DemoQueueItem]?
}

private struct DemoUser: Decodable {
    let id: String
    let displayName: String
}

private struct DemoCourse: Decodable {
    let id: String
    let title: String
}

private struct DemoMembership: Decodable {
    let userId: String
    let courseId: String
    let roleInCourse: String
}

private struct DemoEntry: Decodable {
    let id: String
    let courseId: String
    let studentId: String
    let createdAt: Date
    let practiceDate: Date
    let goalText: String
    let durationSeconds: Int?
    let tags: [String]
    let notes: String?
    let status: String
    let kind: String?
    let consentConfirmedAt: Date?
    let consentScope: String?
    let captureProfile: String?
}

private struct DemoArtifact: Decodable {
    let id: String
    let entryId: String
    let type: String
    let durationSeconds: Int
    let createdAt: Date
    let uploadState: String
    let syncPhase: String
    let storageKey: String?
    let remoteUrl: String?
    let localPath: String
}

private struct DemoFeedback: Decodable {
    let id: String
    let targetType: String
    let targetId: String
    let teacherId: String
    let createdAt: Date
    let status: String
    let commentsText: String
    let markers: [DemoMarker]
}

private struct DemoMarker: Decodable {
    let id: String
    let timeSeconds: Int
    let text: String
}

private struct DemoQueueItem: Decodable {
    let id: String
    let type: String
    let status: String
    let retryCount: Int
    let lastError: String?
    let createdAt: Date
    let nextAttemptAt: Date?
    let payload: [String: String]
}
