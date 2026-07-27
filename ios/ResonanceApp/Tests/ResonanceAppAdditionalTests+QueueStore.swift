import XCTest
import SwiftData
@testable import ResonanceApp

// Purpose: verifies queue identity and persistence rules for synchronization command work.

final class SyncCommandEntityIdentityTests: XCTestCase {
    @MainActor
    func testArtifactTargetedFeedbackUsesItsParentEntryAsTheCommandWaveIdentity() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let entry = LocalPracticeEntry(
            id: "entry-feedback-wave",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(
                practiceDate: Date(),
                goalText: "Review",
                durationSeconds: nil,
                tags: [],
                notes: nil
            ),
            status: .submitted
        )
        let artifact = LocalArtifact(
            id: "artifact-feedback-wave",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 30,
            localPath: ""
        )
        let feedback = LocalFeedback(
            id: "feedback-wave",
            targetType: "artifact",
            targetId: artifact.id,
            teacherName: "Teacher",
            status: .accepted,
            commentsText: "Good work"
        )
        entry.artifacts.append(artifact)
        container.mainContext.insert(entry)
        container.mainContext.insert(artifact)
        container.mainContext.insert(feedback)
        try container.mainContext.save()
        let executor = makeTaskExecutor(for: container.mainContext)
        let item = SyncQueueItem(
            id: "feedback-operation",
            type: SyncTaskType.postFeedback.rawValue,
            payloadJSON: "{\"feedbackId\":\"\(feedback.id)\",\"targetId\":\"\(artifact.id)\"}"
        )

        XCTAssertEqual(try executor.commandEntityID(for: item), entry.id)
        let result = SyncCommandResult(
            operationId: item.id,
            entityId: feedback.id,
            kind: .createFeedback,
            status: .conflict,
            code: "VERSION_CONFLICT",
            message: "Entry changed",
            currentVersion: 4,
            resource: nil
        )
        assertConflict(result, item: item, expectedEntryID: entry.id, executor: executor)
    }

    @MainActor
    private func assertConflict(
        _ result: SyncCommandResult,
        item: SyncQueueItem,
        expectedEntryID: String,
        executor: TaskExecutor
    ) {
        do {
            try executor.apply(result, for: item)
            XCTFail("Expected the stored conflict to identify the parent entry")
        } catch let SyncError.serverConflict(entityId, currentVersion) {
            XCTAssertEqual(entityId, expectedEntryID)
            XCTAssertEqual(currentVersion, 4)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class QueueStoreTests: XCTestCase {

    @MainActor
    private func makeStore() -> (container: ModelContainer, store: QueueStore) {
        let container = PersistenceController.createContainer(inMemory: true)
        let store = QueueStore(modelContext: container.mainContext)
        return (container, store)
    }

    // MARK: enqueue / counts

    @MainActor
    func testEnqueueInsertsItemWithCorrectType() throws {
        let (container, store) = makeStore()
        store.enqueue(type: .createEntry, payload: ["entryId": "e-1"], ownerId: "owner-1")
        let items = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.type, SyncTaskType.createEntry.rawValue)
        XCTAssertEqual(items.first?.status, SyncStatus.pending.rawValue)
    }

    @MainActor
    func testEnqueueRejectsInvalidPayload() throws {
        let (container, store) = makeStore()
        store.enqueue(type: .createEntry, payload: ["nan": Double.nan], ownerId: "owner-1")
        let items = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertTrue(items.isEmpty)
    }

    @MainActor
    func testEnqueueCoalescesRepeatedEntityTaskAndResetsFailure() throws {
        let (container, store) = makeStore()
        store.enqueue(type: .updateEntry, payload: ["entryId": "entry-1", "version": 1], ownerId: "owner-1")
        let initial = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<SyncQueueItem>()).first
        )
        initial.status = SyncStatus.failed.rawValue
        initial.retryCount = 3
        initial.lastError = "offline"
        try container.mainContext.save()

        store.enqueue(type: .updateEntry, payload: ["entryId": "entry-1", "version": 2], ownerId: "owner-1")

        let items = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].status, SyncStatus.pending.rawValue)
        XCTAssertEqual(items[0].retryCount, 0)
        XCTAssertNil(items[0].lastError)
        XCTAssertTrue(items[0].payloadJSON.contains("\"version\":2"))
    }

    @MainActor
    func testCountsReturnCorrectValues() throws {
        let (container, store) = makeStore()
        let pending = SyncQueueItem(id: "p", type: "createEntry", payloadJSON: "{}", ownerId: "owner-1")
        pending.status = SyncStatus.pending.rawValue
        container.mainContext.insert(pending)

        let failed = SyncQueueItem(id: "f", type: "createEntry", payloadJSON: "{}", ownerId: "owner-1")
        failed.status = SyncStatus.failed.rawValue
        container.mainContext.insert(failed)
        try container.mainContext.save()

        let (pendingCount, failedCount) = store.counts(ownerId: "owner-1")
        XCTAssertEqual(pendingCount, 1)
        XCTAssertEqual(failedCount, 1)
    }

    // MARK: fetchReady

    @MainActor
    func testFetchReadyFiltersItemsWithFutureNextAttemptAt() throws {
        let (container, store) = makeStore()
        let now = Date()

        let ready = SyncQueueItem(id: "ready", type: "createEntry", payloadJSON: "{}", ownerId: "owner-1")
        ready.status = SyncStatus.pending.rawValue
        ready.nextAttemptAt = nil
        container.mainContext.insert(ready)

        let notYet = SyncQueueItem(id: "not-yet", type: "createEntry", payloadJSON: "{}", ownerId: "owner-1")
        notYet.status = SyncStatus.pending.rawValue
        notYet.nextAttemptAt = now.addingTimeInterval(60)
        container.mainContext.insert(notYet)

        try container.mainContext.save()

        let fetched = try store.fetchReady(now: now, ownerId: "owner-1")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, "ready")
    }

    // MARK: resetAllFailed

    @MainActor
    func testResetAllFailedClearsErrorAndNextAttempt() throws {
        let (container, store) = makeStore()
        let item = SyncQueueItem(id: "fail-1", type: "createEntry", payloadJSON: "{}", ownerId: "owner-1")
        item.status = SyncStatus.failed.rawValue
        item.lastError = "some error"
        item.nextAttemptAt = Date().addingTimeInterval(60)
        container.mainContext.insert(item)
        try container.mainContext.save()

        store.resetAllFailed(ownerId: "owner-1")

        let fetched = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(fetched.first?.status, SyncStatus.pending.rawValue)
        XCTAssertNil(fetched.first?.lastError)
        XCTAssertNil(fetched.first?.nextAttemptAt)
    }

    @MainActor
    func testResetAllFailedResetsSyncArtifactPhaseToQueued() throws {
        let (container, store) = makeStore()
        let entry = makeDraftPracticeEntry(id: "entry-1")
        let artifact = LocalArtifact(
            id: "artifact-1",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 30,
            localPath: "/tmp/artifact-1.m4a"
        )
        artifact.uploadState = .uploading
        artifact.syncPhase = .confirming
        entry.artifacts.append(artifact)
        container.mainContext.insert(entry)
        container.mainContext.insert(artifact)

        let payloadData = try JSONSerialization.data(withJSONObject: ["artifactId": artifact.id])
        let payloadJSON = try XCTUnwrap(String(bytes: payloadData, encoding: .utf8))
        let item = SyncQueueItem(
            id: "sync-artifact",
            type: SyncTaskType.syncArtifact.rawValue,
            payloadJSON: payloadJSON,
            ownerId: "owner-1"
        )
        item.status = SyncStatus.failed.rawValue
        container.mainContext.insert(item)
        try container.mainContext.save()

        store.resetAllFailed(ownerId: "owner-1")

        XCTAssertEqual(item.status, SyncStatus.pending.rawValue)
        XCTAssertEqual(artifact.uploadState, .pending)
        XCTAssertEqual(artifact.syncPhase, .queued)
    }

    // MARK: resetStuckProcessing

    @MainActor
    func testResetStuckProcessingResetsToPending() throws {
        let (container, store) = makeStore()
        let item = SyncQueueItem(id: "stuck", type: "syncArtifact", payloadJSON: "{}")
        item.status = SyncStatus.processing.rawValue
        container.mainContext.insert(item)
        try container.mainContext.save()

        store.resetStuckProcessing()

        let fetched = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(fetched.first?.status, SyncStatus.pending.rawValue)
    }

    @MainActor
    func testInitializationRecoversPersistedProcessingItemAfterReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storeURL = directory.appendingPathComponent("queue.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let initialContainer = try makePersistentQueueContainer(at: storeURL)
            let item = SyncQueueItem(id: "interrupted", type: SyncTaskType.createEntry.rawValue, payloadJSON: "{}", ownerId: "owner-1")
            item.status = SyncStatus.processing.rawValue
            item.nextAttemptAt = Date().addingTimeInterval(60)
            initialContainer.mainContext.insert(item)
            try initialContainer.mainContext.save()
        }

        let reopenedContainer = try makePersistentQueueContainer(at: storeURL)
        let reopenedStore = QueueStore(modelContext: reopenedContainer.mainContext)
        let recovered = try XCTUnwrap(
            reopenedContainer.mainContext.fetch(FetchDescriptor<SyncQueueItem>()).first
        )

        XCTAssertEqual(recovered.status, SyncStatus.pending.rawValue)
        XCTAssertNil(recovered.nextAttemptAt)
        XCTAssertEqual(try reopenedStore.fetchReady(now: Date(), ownerId: "owner-1").map(\.id), ["interrupted"])
    }

    // MARK: delete

    @MainActor
    func testDeleteRemovesItem() throws {
        let (container, store) = makeStore()
        let item = SyncQueueItem(id: "to-delete", type: "submitEntry", payloadJSON: "{}")
        container.mainContext.insert(item)
        try container.mainContext.save()

        store.delete(item)
        store.save()

        let fetched = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertTrue(fetched.isEmpty)
    }

    @MainActor
    private func makePersistentQueueContainer(at storeURL: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "QueueRecovery",
            schema: PersistenceController.modelSchema(),
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: PersistenceController.modelSchema(), configurations: [configuration])
    }
}

final class FeedbackMarkerFormatTests: XCTestCase {
    @MainActor
    func testParsesMinutesAndSeconds() {
        XCTAssertEqual(FeedbackEditorView.parse("01:24"), 84)
        XCTAssertEqual(FeedbackEditorView.parse("9"), 9)
        XCTAssertNil(FeedbackEditorView.parse("1:60"))
        XCTAssertNil(FeedbackEditorView.parse("-1:10"))
    }

    @MainActor
    func testFormatsPlaybackTime() {
        XCTAssertEqual(FeedbackEditorView.format(84.9), "01:24")
    }
}

final class DemoDataCleanupTests: XCTestCase {
    @MainActor
    func testClearMockDataRemovesUUIDQueueRowsByPayloadAndDeletesArtifactFile() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let context = container.mainContext
        let entry = LocalPracticeEntry(
            id: "demo_entry_cleanup",
            courseId: "demo_course_cleanup",
            studentId: "demo_student_cleanup",
            details: PracticeEntryDetails(practiceDate: Date(), goalText: "Demo", durationSeconds: nil, tags: [], notes: nil),
            status: .draft
        )
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("demo-cleanup-artifact.m4a")
        try Data("demo-media".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let artifact = LocalArtifact(
            id: "demo_artifact_cleanup",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 1,
            localPath: fileURL.path
        )
        let feedback = LocalFeedback(
            id: "demo_feedback_cleanup",
            targetType: "artifact",
            targetId: artifact.id,
            teacherName: "Demo Teacher",
            status: .accepted,
            commentsText: "Demo"
        )
        entry.artifacts.append(artifact)
        entry.feedback.append(feedback)
        context.insert(entry)
        context.insert(artifact)
        context.insert(feedback)
        let demoQueueItems = try [
            makeQueueItem(type: .createEntry, payload: ["entryId": entry.id]),
            makeQueueItem(type: .syncArtifact, payload: ["artifactId": artifact.id]),
            makeQueueItem(type: .postFeedback, payload: ["feedbackId": feedback.id, "targetId": artifact.id])
        ]
        demoQueueItems.forEach { context.insert($0) }
        let nonDemoQueueItem = try makeQueueItem(type: .createEntry, payload: ["entryId": "entry-real"])
        context.insert(nonDemoQueueItem)
        try context.save()

        try DemoDataManager(modelContext: context).clearMockUniversityData()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(try context.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<LocalArtifact>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<LocalFeedback>()).isEmpty)
        let remainingQueueItems = try context.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(remainingQueueItems.map(\.id), [nonDemoQueueItem.id])
    }

    private func makeQueueItem(type: SyncTaskType, payload: [String: Any]) throws -> SyncQueueItem {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let payloadJSON = try XCTUnwrap(String(data: data, encoding: .utf8))
        return SyncQueueItem(id: UUID().uuidString, type: type.rawValue, payloadJSON: payloadJSON)
    }
}
