import XCTest
import SwiftData
@testable import ResonanceApp

final class ResonanceAppTests: XCTestCase {
    @MainActor
    func testTagsRoundTripWithCommas() {
        let entry = LocalPracticeEntry(
            id: "entry-1",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(practiceDate: Date(), goalText: "Goal", durationSeconds: nil, tags: ["alpha,beta", "gamma"], notes: nil),
            status: .draft
        )

        XCTAssertEqual(entry.tags, ["alpha,beta", "gamma"])

        entry.tags = ["delta,epsilon", "zeta"]
        XCTAssertEqual(entry.tags, ["delta,epsilon", "zeta"])
    }

    @MainActor
    func testTeachingLessonConsentFieldsRoundTrip() {
        let consentDate = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = LocalPracticeEntry(
            id: "entry-teaching",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(practiceDate: Date(), goalText: "Teach rhythm ostinato", durationSeconds: nil, tags: ["lehramt"], notes: nil),
            status: .draft,
            captureContext: CaptureContext(kind: .teachingLesson, consentConfirmedAt: consentDate, consentScope: .privateCourseReview, captureProfile: nil)
        )

        XCTAssertEqual(entry.kind, .teachingLesson)
        XCTAssertEqual(entry.consentConfirmedAt, consentDate)
        XCTAssertEqual(entry.consentScope, .privateCourseReview)
    }

    @MainActor
    func testSyncQueueEnqueue() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let client = APIClient()
        let auth = AuthManager(apiClient: client)
        let syncManager = SyncManager(modelContext: container.mainContext, authManager: auth, apiClient: client)

        syncManager.enqueue(type: .createEntry, payload: ["entryId": "entry-1"])

        let items = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.type, SyncTaskType.createEntry.rawValue)
    }

    func testICalParser() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:123
SUMMARY:Room 101
DTSTART:20250101T120000Z
DTEND:20250101T130000Z
LOCATION:Building A
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.summary, "Room 101")
    }
}

// MARK: - SyncManager Queue State Machine Tests

final class SyncManagerTests: XCTestCase {

    /// Creates an in-memory ModelContainer and returns it alongside a SyncManager wired to its mainContext.
    @MainActor
    private func makeSUT() -> (container: ModelContainer, syncManager: SyncManager) {
        let container = PersistenceController.createContainer(inMemory: true)
        let client = APIClient()
        let auth = AuthManager(apiClient: client)
        let syncManager = SyncManager(modelContext: container.mainContext, authManager: auth, apiClient: client)
        return (container, syncManager)
    }

    // MARK: 1 — retryFailedItems resets status

    @MainActor
    func testRetryFailedItemsResetsStatusToPending() throws {
        let (container, syncManager) = makeSUT()
        let ctx = container.mainContext

        // Insert items with "failed" status, a lastError, and a nextAttemptAt date.
        let item1 = SyncQueueItem(id: "fail-1", type: "createEntry", payloadJSON: "{}")
        item1.status = "failed"
        item1.retryCount = 3
        item1.lastError = "Server timeout"
        item1.nextAttemptAt = Date().addingTimeInterval(60)
        ctx.insert(item1)

        let item2 = SyncQueueItem(id: "fail-2", type: "syncArtifact", payloadJSON: "{}")
        item2.status = "failed"
        item2.retryCount = 5
        item2.lastError = "Network error"
        item2.nextAttemptAt = Date().addingTimeInterval(120)
        ctx.insert(item2)

        try ctx.save()

        // Act
        syncManager.retryFailedItems()

        // Assert
        let all = try ctx.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(all.count, 2)
        for item in all {
            XCTAssertEqual(item.status, "pending", "Status should be reset to pending")
            XCTAssertNil(item.lastError, "lastError should be cleared")
            XCTAssertNil(item.nextAttemptAt, "nextAttemptAt should be reset to nil")
        }
    }

    @MainActor
    func testRetryFailedItemsDoesNotAffectPendingItems() throws {
        let (container, syncManager) = makeSUT()
        let ctx = container.mainContext

        let pending = SyncQueueItem(id: "pend-1", type: "createEntry", payloadJSON: "{}")
        pending.status = "pending"
        pending.nextAttemptAt = Date().addingTimeInterval(30)
        ctx.insert(pending)

        let failed = SyncQueueItem(id: "fail-1", type: "createEntry", payloadJSON: "{}")
        failed.status = "failed"
        failed.lastError = "some error"
        ctx.insert(failed)

        try ctx.save()

        syncManager.retryFailedItems()

        // The pending item should still have its original nextAttemptAt
        let pendingItems = try ctx.fetch(FetchDescriptor<SyncQueueItem>(predicate: #Predicate { $0.id == "pend-1" }))
        XCTAssertEqual(pendingItems.first?.status, "pending")
        XCTAssertNotNil(pendingItems.first?.nextAttemptAt, "Pending item's nextAttemptAt should not be altered")

        let failedItems = try ctx.fetch(FetchDescriptor<SyncQueueItem>(predicate: #Predicate { $0.id == "fail-1" }))
        XCTAssertEqual(failedItems.first?.status, "pending")
        XCTAssertNil(failedItems.first?.lastError)
    }

    // MARK: 2 — Exponential backoff calculation (via RetryPolicy)

    func testExponentialBackoffRetryCount0() {
        XCTAssertEqual(RetryPolicy().backoffDelay(retryCount: 0), 1.0, accuracy: 0.001)
    }

    func testExponentialBackoffRetryCount3() {
        XCTAssertEqual(RetryPolicy().backoffDelay(retryCount: 3), 8.0, accuracy: 0.001)
    }

    func testExponentialBackoffRetryCount10CapsAt300() {
        XCTAssertEqual(RetryPolicy().backoffDelay(retryCount: 10), 300.0, accuracy: 0.001)
    }

    func testExponentialBackoffRetryCount8Below300() {
        XCTAssertEqual(RetryPolicy().backoffDelay(retryCount: 8), 256.0, accuracy: 0.001)
    }

    func testExponentialBackoffRetryCount9ExceedsCap() {
        XCTAssertEqual(RetryPolicy().backoffDelay(retryCount: 9), 300.0, accuracy: 0.001)
    }

    // MARK: 3 — FIFO ordering

    @MainActor
    func testFIFOOrderingBySortDescriptor() throws {
        let (container, _) = makeSUT()
        let ctx = container.mainContext

        let now = Date()
        let item1 = SyncQueueItem(id: "fifo-1", type: "createEntry", payloadJSON: "{}")
        item1.createdAt = now.addingTimeInterval(-30) // oldest
        ctx.insert(item1)

        let item2 = SyncQueueItem(id: "fifo-2", type: "syncArtifact", payloadJSON: "{}")
        item2.createdAt = now.addingTimeInterval(-10) // newest
        ctx.insert(item2)

        let item3 = SyncQueueItem(id: "fifo-3", type: "submitEntry", payloadJSON: "{}")
        item3.createdAt = now.addingTimeInterval(-20) // middle
        ctx.insert(item3)

        try ctx.save()

        // Replicate the same FetchDescriptor used in processQueue
        var descriptor = FetchDescriptor<SyncQueueItem>(predicate: #Predicate { $0.status == "pending" })
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .forward)]

        let fetched = try ctx.fetch(descriptor)
        XCTAssertEqual(fetched.count, 3)
        XCTAssertEqual(fetched[0].id, "fifo-1", "Oldest item should be first (FIFO)")
        XCTAssertEqual(fetched[1].id, "fifo-3", "Middle item should be second")
        XCTAssertEqual(fetched[2].id, "fifo-2", "Newest item should be last")
    }

    // MARK: 4 — Background expiration resets processing items

    @MainActor
    func testBackgroundExpirationResetsProcessingToPending() throws {
        let (container, _) = makeSUT()
        let ctx = container.mainContext

        // Simulate items stuck in "processing" state (as would happen during background task expiry)
        let item1 = SyncQueueItem(id: "proc-1", type: "syncArtifact", payloadJSON: "{}")
        item1.status = "processing"
        item1.nextAttemptAt = Date().addingTimeInterval(60)
        ctx.insert(item1)

        let item2 = SyncQueueItem(id: "proc-2", type: "createEntry", payloadJSON: "{}")
        item2.status = "processing"
        ctx.insert(item2)

        // A pending item should not be touched
        let pendingItem = SyncQueueItem(id: "pend-1", type: "submitEntry", payloadJSON: "{}")
        pendingItem.status = "pending"
        ctx.insert(pendingItem)

        try ctx.save()

        // Simulate the expiration handler logic from processQueue
        let stuckDescriptor = FetchDescriptor<SyncQueueItem>(predicate: #Predicate { $0.status == "processing" })
        let stuck = try ctx.fetch(stuckDescriptor)
        for item in stuck {
            item.status = "pending"
            item.nextAttemptAt = nil
        }
        try ctx.save()

        // Verify processing items were reset
        let allItems = try ctx.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(allItems.count, 3)

        let resetItems = try ctx.fetch(FetchDescriptor<SyncQueueItem>(predicate: #Predicate { $0.id == "proc-1" || $0.id == "proc-2" }))
        for item in resetItems {
            XCTAssertEqual(item.status, "pending", "Processing items should be reset to pending on background expiry")
            XCTAssertNil(item.nextAttemptAt, "nextAttemptAt should be cleared on background expiry")
        }

        // Pending item should remain unchanged
        let pendingFetch = try ctx.fetch(FetchDescriptor<SyncQueueItem>(predicate: #Predicate { $0.id == "pend-1" }))
        XCTAssertEqual(pendingFetch.first?.status, "pending")
    }

    // MARK: 5 — Enqueue with JSON serialization failure

    @MainActor
    func testEnqueueWithInvalidPayloadDoesNotInsertItem() throws {
        let (container, syncManager) = makeSUT()
        let ctx = container.mainContext

        // Double.nan is not valid JSON and will cause JSONSerialization to throw.
        let invalidPayload: [String: Any] = ["value": Double.nan]

        syncManager.enqueue(type: .createEntry, payload: invalidPayload)

        // The item should NOT be inserted into the store (logged, not silently dropped).
        let items = try ctx.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(items.count, 0, "Invalid payloads should be rejected, not inserted")
    }

    @MainActor
    func testEnqueueWithValidPayloadInsertsItem() throws {
        let (container, syncManager) = makeSUT()
        let ctx = container.mainContext

        let validPayload: [String: Any] = ["entryId": "entry-42"]

        syncManager.enqueue(type: .createEntry, payload: validPayload)

        let items = try ctx.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(items.count, 1, "Valid payloads should be inserted")
    }

    // MARK: 6 — Queue item creation fields

    @MainActor
    func testEnqueueCreatesItemWithCorrectFields() throws {
        let (container, syncManager) = makeSUT()
        let ctx = container.mainContext

        let beforeEnqueue = Date()
        syncManager.enqueue(type: .deleteEntry, payload: ["entryId": "entry-99"])
        let afterEnqueue = Date()

        let items = try ctx.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(items.count, 1)

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.type, SyncTaskType.deleteEntry.rawValue, "Type should match the enqueued task type")
        XCTAssertEqual(item.status, "pending", "Initial status should be 'pending'")
        XCTAssertEqual(item.retryCount, 0, "Initial retryCount should be 0")
        XCTAssertNil(item.lastError, "Initial lastError should be nil")
        XCTAssertNil(item.nextAttemptAt, "Initial nextAttemptAt should be nil")
        XCTAssertFalse(item.id.isEmpty, "ID should be a non-empty UUID string")

        // createdAt should be within the time window of the enqueue call
        XCTAssertGreaterThanOrEqual(item.createdAt, beforeEnqueue)
        XCTAssertLessThanOrEqual(item.createdAt, afterEnqueue)

        // payloadJSON should round-trip back to the original dictionary
        let data = try XCTUnwrap(item.payloadJSON.data(using: .utf8))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["entryId"] as? String, "entry-99")
    }

    @MainActor
    func testEnqueueDifferentTypesStoresCorrectRawValue() throws {
        let (container, syncManager) = makeSUT()
        let ctx = container.mainContext

        let types: [SyncTaskType] = [
            .createEntry,
            .syncArtifact,
            .syncCaptureProfile,
            .syncCaptureMarkers,
            .submitEntry,
            .deleteEntry,
            .postFeedback
        ]

        for (index, taskType) in types.enumerated() {
            syncManager.enqueue(type: taskType, payload: ["index": index])
        }

        var descriptor = FetchDescriptor<SyncQueueItem>()
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .forward)]
        let items = try ctx.fetch(descriptor)
        XCTAssertEqual(items.count, types.count)

        for (index, taskType) in types.enumerated() {
            XCTAssertEqual(items[index].type, taskType.rawValue,
                           "Item at index \(index) should have type '\(taskType.rawValue)'")
        }
    }
}

// MARK: - Model Enum Raw Value Tests

final class ModelEnumRawValueTests: XCTestCase {

    // EntryStatus raw values must match server strings
    func testEntryStatusRawValues() {
        XCTAssertEqual(EntryStatus.draft.rawValue, "draft")
        XCTAssertEqual(EntryStatus.submitted.rawValue, "submitted")
        XCTAssertEqual(EntryStatus.reviewed.rawValue, "reviewed")
    }

    // ArtifactType raw values must match server strings
    func testArtifactTypeRawValues() {
        XCTAssertEqual(ArtifactType.audio.rawValue, "audio")
        XCTAssertEqual(ArtifactType.video.rawValue, "video")
    }

    func testEntryKindRawValues() {
        XCTAssertEqual(EntryKind.practice.rawValue, "practice")
        XCTAssertEqual(EntryKind.teachingLesson.rawValue, "teaching_lesson")
    }

    func testConsentScopeRawValues() {
        XCTAssertEqual(ConsentScope.privateCourseReview.rawValue, "private_course_review")
    }

    func testCaptureProfileRawValues() {
        XCTAssertEqual(CaptureProfile.roomOverview.rawValue, "room_overview")
        XCTAssertEqual(CaptureProfile.teacherLearner.rawValue, "teacher_learner")
        XCTAssertEqual(CaptureProfile.instrumentCloseup.rawValue, "instrument_closeup")
        XCTAssertEqual(CaptureProfile.ensembleGroup.rawValue, "ensemble_group")
        XCTAssertEqual(CaptureProfile.groupWork.rawValue, "group_work")
    }

    func testCaptureMarkerKindRawValues() {
        XCTAssertEqual(CaptureMarkerKind.phaseSetup.rawValue, "phase_setup")
        XCTAssertEqual(CaptureMarkerKind.phaseModeling.rawValue, "phase_modeling")
        XCTAssertEqual(CaptureMarkerKind.phaseGuidedPractice.rawValue, "phase_guided_practice")
        XCTAssertEqual(CaptureMarkerKind.phaseStudentWork.rawValue, "phase_student_work")
        XCTAssertEqual(CaptureMarkerKind.phaseFeedback.rawValue, "phase_feedback")
        XCTAssertEqual(CaptureMarkerKind.phaseReflection.rawValue, "phase_reflection")
        XCTAssertEqual(CaptureMarkerKind.momentQuestion.rawValue, "moment_question")
        XCTAssertEqual(CaptureMarkerKind.momentMusicalModel.rawValue, "moment_musical_model")
        XCTAssertEqual(CaptureMarkerKind.momentStudentResponse.rawValue, "moment_student_response")
        XCTAssertEqual(CaptureMarkerKind.momentTransition.rawValue, "moment_transition")
        XCTAssertEqual(CaptureMarkerKind.privacyNote.rawValue, "privacy_note")
    }

    // UploadState raw values must match server strings
    func testUploadStateRawValues() {
        XCTAssertEqual(UploadState.pending.rawValue, "pending")
        XCTAssertEqual(UploadState.uploading.rawValue, "uploading")
        XCTAssertEqual(UploadState.uploaded.rawValue, "uploaded")
        XCTAssertEqual(UploadState.failed.rawValue, "failed")
    }

    // ArtifactSyncPhase raw values
    func testArtifactSyncPhaseRawValues() {
        XCTAssertEqual(ArtifactSyncPhase.queued.rawValue, "queued")
        XCTAssertEqual(ArtifactSyncPhase.uploading.rawValue, "uploading")
        XCTAssertEqual(ArtifactSyncPhase.confirming.rawValue, "confirming")
        XCTAssertEqual(ArtifactSyncPhase.uploaded.rawValue, "uploaded")
        XCTAssertEqual(ArtifactSyncPhase.failed.rawValue, "failed")
    }

    // FeedbackStatus raw values — note snake_case mapping
    func testFeedbackStatusRawValues() {
        XCTAssertEqual(FeedbackStatus.ok.rawValue, "ok")
        XCTAssertEqual(FeedbackStatus.needsRevision.rawValue, "needs_revision")
        XCTAssertEqual(FeedbackStatus.nextGoal.rawValue, "next_goal")
    }

    // Verify enums round-trip through init(rawValue:)
    func testEntryStatusInitFromRawValue() {
        XCTAssertEqual(EntryStatus(rawValue: "draft"), .draft)
        XCTAssertEqual(EntryStatus(rawValue: "submitted"), .submitted)
        XCTAssertEqual(EntryStatus(rawValue: "reviewed"), .reviewed)
        XCTAssertNil(EntryStatus(rawValue: "bogus"))
    }

    func testFeedbackStatusInitFromRawValue() {
        XCTAssertEqual(FeedbackStatus(rawValue: "ok"), .ok)
        XCTAssertEqual(FeedbackStatus(rawValue: "needs_revision"), .needsRevision)
        XCTAssertEqual(FeedbackStatus(rawValue: "next_goal"), .nextGoal)
        XCTAssertNil(FeedbackStatus(rawValue: "NEEDS_REVISION"))
    }

    func testUploadStateInitFromRawValue() {
        XCTAssertEqual(UploadState(rawValue: "pending"), .pending)
        XCTAssertEqual(UploadState(rawValue: "failed"), .failed)
        XCTAssertNil(UploadState(rawValue: ""))
    }

    func testArtifactTypeInitFromRawValue() {
        XCTAssertEqual(ArtifactType(rawValue: "audio"), .audio)
        XCTAssertEqual(ArtifactType(rawValue: "video"), .video)
        XCTAssertNil(ArtifactType(rawValue: "image"))
    }
}
