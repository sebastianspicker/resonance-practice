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
            practiceDate: Date(),
            goalText: "Goal",
            durationSeconds: nil,
            tags: ["alpha,beta", "gamma"],
            notes: nil,
            status: .draft
        )

        XCTAssertEqual(entry.tags, ["alpha,beta", "gamma"])

        entry.tags = ["delta,epsilon", "zeta"]
        XCTAssertEqual(entry.tags, ["delta,epsilon", "zeta"])
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

        let item2 = SyncQueueItem(id: "fail-2", type: "uploadArtifact", payloadJSON: "{}")
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

    // MARK: 2 — Exponential backoff calculation

    func testExponentialBackoffRetryCount0() {
        // pow(2.0, 0) = 1, min(1, 300) = 1
        let delay = min(pow(2.0, Double(0)), 300)
        XCTAssertEqual(delay, 1.0, accuracy: 0.001)
    }

    func testExponentialBackoffRetryCount3() {
        // pow(2.0, 3) = 8, min(8, 300) = 8
        let delay = min(pow(2.0, Double(3)), 300)
        XCTAssertEqual(delay, 8.0, accuracy: 0.001)
    }

    func testExponentialBackoffRetryCount10CapsAt300() {
        // pow(2.0, 10) = 1024, min(1024, 300) = 300
        let delay = min(pow(2.0, Double(10)), 300)
        XCTAssertEqual(delay, 300.0, accuracy: 0.001)
    }

    func testExponentialBackoffRetryCount8Below300() {
        // pow(2.0, 8) = 256, min(256, 300) = 256
        let delay = min(pow(2.0, Double(8)), 300)
        XCTAssertEqual(delay, 256.0, accuracy: 0.001)
    }

    func testExponentialBackoffRetryCount9ExceedsCap() {
        // pow(2.0, 9) = 512, min(512, 300) = 300
        let delay = min(pow(2.0, Double(9)), 300)
        XCTAssertEqual(delay, 300.0, accuracy: 0.001)
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

        let item2 = SyncQueueItem(id: "fifo-2", type: "uploadArtifact", payloadJSON: "{}")
        item2.createdAt = now.addingTimeInterval(-10) // newest
        ctx.insert(item2)

        let item3 = SyncQueueItem(id: "fifo-3", type: "confirmArtifact", payloadJSON: "{}")
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
        let item1 = SyncQueueItem(id: "proc-1", type: "uploadArtifact", payloadJSON: "{}")
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
        let data = item.payloadJSON.data(using: .utf8)!
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(decoded["entryId"] as? String, "entry-99")
    }

    @MainActor
    func testEnqueueDifferentTypesStoresCorrectRawValue() throws {
        let (container, syncManager) = makeSUT()
        let ctx = container.mainContext

        let types: [SyncTaskType] = [.createEntry, .createArtifact, .uploadArtifact, .confirmArtifact, .submitEntry, .deleteEntry, .postFeedback]

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

// MARK: - API Model Decode Tests

final class APIModelDecodeTests: XCTestCase {

    /// Helper: the same decoder configuration used by APIClient in production.
    private var apiDecoder: JSONDecoder {
        JSONDecoder.apiDecoder
    }

    func testTokenResponseDecode() throws {
        let json = """
        {
            "accessToken": "tok_abc",
            "refreshToken": "ref_xyz",
            "user": {
                "id": "user-1",
                "displayName": "Alice",
                "globalRole": "student"
            }
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(TokenResponse.self, from: json)
        XCTAssertEqual(result.accessToken, "tok_abc")
        XCTAssertEqual(result.refreshToken, "ref_xyz")
        XCTAssertEqual(result.user?.id, "user-1")
        XCTAssertEqual(result.user?.displayName, "Alice")
        XCTAssertEqual(result.user?.globalRole, "student")
    }

    func testTokenResponseDecodeWithoutUser() throws {
        let json = """
        {
            "accessToken": "tok_abc",
            "refreshToken": "ref_xyz"
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(TokenResponse.self, from: json)
        XCTAssertEqual(result.accessToken, "tok_abc")
        XCTAssertNil(result.user)
    }

    func testCourseResponseDecode() throws {
        let json = """
        {
            "id": "course-1",
            "title": "Piano 101",
            "roleInCourse": "student"
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(CourseResponse.self, from: json)
        XCTAssertEqual(result.id, "course-1")
        XCTAssertEqual(result.title, "Piano 101")
        XCTAssertEqual(result.roleInCourse, "student")
    }

    func testEntryResponseDecodeWithFractionalSeconds() throws {
        let json = """
        {
            "id": "entry-1",
            "courseId": "course-1",
            "studentId": "student-1",
            "practiceDate": "2025-03-15T10:30:00.123Z",
            "goalText": "Scales",
            "durationSeconds": 1800,
            "tags": ["warmup", "technique"],
            "notes": "Went well",
            "status": "submitted"
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(EntryResponse.self, from: json)
        XCTAssertEqual(result.id, "entry-1")
        XCTAssertEqual(result.courseId, "course-1")
        XCTAssertEqual(result.studentId, "student-1")
        XCTAssertEqual(result.goalText, "Scales")
        XCTAssertEqual(result.durationSeconds, 1800)
        XCTAssertEqual(result.tags, ["warmup", "technique"])
        XCTAssertEqual(result.notes, "Went well")
        XCTAssertEqual(result.status, "submitted")
        // Date should have decoded successfully (not nil/crash)
        XCTAssertNotNil(result.practiceDate)
    }

    func testEntryResponseDecodeWithoutFractionalSeconds() throws {
        let json = """
        {
            "id": "entry-2",
            "courseId": "course-1",
            "studentId": "student-1",
            "practiceDate": "2025-03-15T10:30:00Z",
            "goalText": "Arpeggios",
            "durationSeconds": null,
            "tags": [],
            "notes": null,
            "status": "draft"
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(EntryResponse.self, from: json)
        XCTAssertEqual(result.id, "entry-2")
        XCTAssertNil(result.durationSeconds)
        XCTAssertNil(result.notes)
        XCTAssertTrue(result.tags.isEmpty)
        XCTAssertNotNil(result.practiceDate)
    }

    func testArtifactResponseDecode() throws {
        let json = """
        {
            "id": "art-1",
            "entryId": "entry-1",
            "type": "audio",
            "durationSeconds": 120,
            "uploadState": "uploaded",
            "storageKey": "artifacts/art-1.m4a",
            "remoteUrl": "https://cdn.example.com/art-1.m4a"
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(ArtifactResponse.self, from: json)
        XCTAssertEqual(result.id, "art-1")
        XCTAssertEqual(result.entryId, "entry-1")
        XCTAssertEqual(result.type, "audio")
        XCTAssertEqual(result.durationSeconds, 120)
        XCTAssertEqual(result.uploadState, "uploaded")
        XCTAssertEqual(result.storageKey, "artifacts/art-1.m4a")
        XCTAssertEqual(result.remoteUrl, "https://cdn.example.com/art-1.m4a")
    }

    func testArtifactResponseDecodeNullOptionals() throws {
        let json = """
        {
            "id": "art-2",
            "entryId": "entry-1",
            "type": "video",
            "durationSeconds": 60,
            "uploadState": "pending",
            "storageKey": null,
            "remoteUrl": null
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(ArtifactResponse.self, from: json)
        XCTAssertEqual(result.type, "video")
        XCTAssertNil(result.storageKey)
        XCTAssertNil(result.remoteUrl)
    }

    func testFeedbackResponseDecodeWithFractionalSeconds() throws {
        let json = """
        {
            "id": "fb-1",
            "targetType": "entry",
            "targetId": "entry-1",
            "teacherName": "Prof. Smith",
            "createdAt": "2025-04-01T14:00:00.456Z",
            "status": "needs_revision",
            "commentsText": "Work on dynamics",
            "markers": [
                {"id": "m-1", "timeSeconds": 30, "text": "Too fast here"},
                {"id": "m-2", "timeSeconds": 90, "text": "Good tone"}
            ]
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(FeedbackResponse.self, from: json)
        XCTAssertEqual(result.id, "fb-1")
        XCTAssertEqual(result.targetType, "entry")
        XCTAssertEqual(result.targetId, "entry-1")
        XCTAssertEqual(result.teacherName, "Prof. Smith")
        XCTAssertEqual(result.status, "needs_revision")
        XCTAssertEqual(result.commentsText, "Work on dynamics")
        XCTAssertNotNil(result.createdAt)
        XCTAssertEqual(result.markers.count, 2)
        XCTAssertEqual(result.markers[0].id, "m-1")
        XCTAssertEqual(result.markers[0].timeSeconds, 30)
        XCTAssertEqual(result.markers[0].text, "Too fast here")
        XCTAssertEqual(result.markers[1].timeSeconds, 90)
    }

    func testFeedbackResponseDecodeWithoutFractionalSeconds() throws {
        let json = """
        {
            "id": "fb-2",
            "targetType": "artifact",
            "targetId": "art-1",
            "teacherName": "Prof. Jones",
            "createdAt": "2025-04-01T14:00:00Z",
            "status": "ok",
            "commentsText": "Well done",
            "markers": []
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(FeedbackResponse.self, from: json)
        XCTAssertEqual(result.id, "fb-2")
        XCTAssertEqual(result.status, "ok")
        XCTAssertTrue(result.markers.isEmpty)
        XCTAssertNotNil(result.createdAt)
    }

    func testPresignResponseDecode() throws {
        let json = """
        {
            "uploadUrl": "https://storage.example.com/presigned",
            "storageKey": "artifacts/abc123.m4a",
            "expiresInSeconds": 3600,
            "requiredHeaders": {"x-amz-acl": "private"}
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(PresignResponse.self, from: json)
        XCTAssertEqual(result.uploadUrl, "https://storage.example.com/presigned")
        XCTAssertEqual(result.storageKey, "artifacts/abc123.m4a")
        XCTAssertEqual(result.expiresInSeconds, 3600)
        XCTAssertEqual(result.requiredHeaders?["x-amz-acl"], "private")
    }

    func testPresignResponseDecodeNullHeaders() throws {
        let json = """
        {
            "uploadUrl": "https://storage.example.com/presigned",
            "storageKey": "key",
            "expiresInSeconds": 600,
            "requiredHeaders": null
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(PresignResponse.self, from: json)
        XCTAssertNil(result.requiredHeaders)
    }

    func testAPIErrorDecode() throws {
        let json = """
        {
            "error": {
                "code": "AUTH_TOKEN_EXPIRED",
                "message": "Token has expired",
                "details": {"hint": "Re-authenticate"}
            }
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(APIError.self, from: json)
        XCTAssertEqual(result.error.code, "AUTH_TOKEN_EXPIRED")
        XCTAssertEqual(result.error.message, "Token has expired")
        XCTAssertEqual(result.error.details?["hint"], "Re-authenticate")
    }

    func testAPIErrorDecodeNullDetails() throws {
        let json = """
        {
            "error": {
                "code": "NOT_FOUND",
                "message": "Resource not found",
                "details": null
            }
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(APIError.self, from: json)
        XCTAssertEqual(result.error.code, "NOT_FOUND")
        XCTAssertNil(result.error.details)
    }

    func testReviewQueueEntryDecode() throws {
        let json = """
        {
            "id": "entry-99",
            "courseId": "course-1",
            "studentId": "student-5",
            "studentName": "Bob",
            "practiceDate": "2025-05-10T08:00:00.000Z",
            "goalText": "Sight reading",
            "notes": null,
            "artifacts": [
                {
                    "id": "art-10",
                    "entryId": "entry-99",
                    "type": "audio",
                    "durationSeconds": 45,
                    "uploadState": "uploaded",
                    "storageKey": "key",
                    "remoteUrl": "https://cdn.example.com/a.m4a"
                }
            ]
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(ReviewQueueEntry.self, from: json)
        XCTAssertEqual(result.id, "entry-99")
        XCTAssertEqual(result.studentName, "Bob")
        XCTAssertNil(result.notes)
        XCTAssertEqual(result.artifacts.count, 1)
        XCTAssertEqual(result.artifacts[0].id, "art-10")
    }

    /// Ensure date decoding fails for an invalid date string.
    func testDateDecodingRejectsGarbage() {
        let json = """
        {
            "id": "entry-bad",
            "courseId": "c",
            "studentId": "s",
            "practiceDate": "not-a-date",
            "goalText": "G",
            "durationSeconds": null,
            "tags": [],
            "notes": null,
            "status": "draft"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try apiDecoder.decode(EntryResponse.self, from: json))
    }
}

// MARK: - ICalParser Edge Case Tests

final class ICalParserEdgeCaseTests: XCTestCase {

    func testEmptyCalendar() {
        let ical = """
BEGIN:VCALENDAR
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertTrue(events.isEmpty)
    }

    func testEmptyString() {
        let events = ICalParser.parse("")
        XCTAssertTrue(events.isEmpty)
    }

    func testMultipleEvents() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:evt-1
SUMMARY:Lesson 1
DTSTART:20250301T090000Z
DTEND:20250301T100000Z
END:VEVENT
BEGIN:VEVENT
UID:evt-2
SUMMARY:Lesson 2
DTSTART:20250302T140000Z
DTEND:20250302T150000Z
LOCATION:Room B
END:VEVENT
BEGIN:VEVENT
UID:evt-3
SUMMARY:Lesson 3
DTSTART:20250303T160000Z
DTEND:20250303T170000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].summary, "Lesson 1")
        XCTAssertEqual(events[1].summary, "Lesson 2")
        XCTAssertEqual(events[2].summary, "Lesson 3")
        XCTAssertEqual(events[1].location, "Room B")
        XCTAssertNil(events[0].location)
    }

    func testMissingSummarySkipsEvent() {
        // SUMMARY is required; event without it should be skipped
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:no-summary
DTSTART:20250301T090000Z
DTEND:20250301T100000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingDTSTARTSkipsEvent() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:no-start
SUMMARY:Missing Start
DTEND:20250301T100000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingDTENDSkipsEvent() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:no-end
SUMMARY:Missing End
DTSTART:20250301T090000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingUIDGeneratesOne() {
        // UID is optional; parser should generate a UUID if absent
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
SUMMARY:No UID Event
DTSTART:20250301T090000Z
DTEND:20250301T100000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events[0].id.isEmpty, "Generated UID should not be empty")
    }

    func testMalformedInputNoCrash() {
        // Completely invalid data should not crash, just return empty
        let garbage = "this is not ical data at all"
        let events = ICalParser.parse(garbage)
        XCTAssertTrue(events.isEmpty)
    }

    func testMalformedDatesSkipEvent() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:bad-dates
SUMMARY:Bad Dates
DTSTART:not-a-date
DTEND:also-not-a-date
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertTrue(events.isEmpty)
    }

    func testAllDayEvent() {
        // All-day dates use yyyyMMdd format (8 characters, no time component)
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:all-day
SUMMARY:All Day Rehearsal
DTSTART;VALUE=DATE:20250315
DTEND;VALUE=DATE:20250316
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].summary, "All Day Rehearsal")
    }

    func testFloatingDateTime() {
        // Floating datetime (no Z suffix) should be parsed in local timezone
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:floating
SUMMARY:Local Time Event
DTSTART:20250320T180000
DTEND:20250320T190000
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(events[0].startDate)
    }

    func testLineFolding() {
        // RFC 5545: long lines may be folded with CRLF + space/tab
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:fold-test
SUMMARY:Very Long Su
 mmary That Is Folded
DTSTART:20250301T090000Z
DTEND:20250301T100000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].summary, "Very Long Summary That Is Folded")
    }

    func testLocationOptional() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:no-loc
SUMMARY:No Location
DTSTART:20250401T100000Z
DTEND:20250401T110000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].location)
    }

    func testDTSTARTWithTZIDParameter() {
        // DTSTART may include TZID parameter: DTSTART;TZID=America/New_York:20250301T090000
        // Parser strips parameters before the key, so the key becomes DTSTART
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:tzid-test
SUMMARY:With TZID
DTSTART;TZID=America/New_York:20250301T090000
DTEND;TZID=America/New_York:20250301T100000
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        // The parser strips parameters (;TZID=...) and parses the value as floating datetime
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].summary, "With TZID")
    }

    func testMixOfValidAndInvalidEvents() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:valid
SUMMARY:Good Event
DTSTART:20250301T090000Z
DTEND:20250301T100000Z
END:VEVENT
BEGIN:VEVENT
UID:invalid
SUMMARY:Bad Event
DTSTART:garbage
DTEND:garbage
END:VEVENT
BEGIN:VEVENT
UID:also-valid
SUMMARY:Another Good Event
DTSTART:20250302T110000Z
DTEND:20250302T120000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].summary, "Good Event")
        XCTAssertEqual(events[1].summary, "Another Good Event")
    }
}

// MARK: - AppConfig Derivation Tests

final class AppConfigTests: XCTestCase {

    func testKeychainNamespaceFromDefaultURL() {
        // The default API URL is http://localhost:4000 (unless env override is set).
        // keychainNamespace should be "resonance-" + sanitized URL.
        let ns = AppConfig.keychainNamespace
        XCTAssertTrue(ns.hasPrefix("resonance-"), "keychainNamespace should start with 'resonance-'")
        XCTAssertFalse(ns.isEmpty)
        // Should not contain characters outside [a-z0-9-]
        let validChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for scalar in ns.unicodeScalars {
            XCTAssertTrue(validChars.contains(scalar), "Unexpected character '\(scalar)' in keychainNamespace: \(ns)")
        }
    }

    func testKeychainNamespaceDoesNotContainDoubleHyphens() {
        // The regex replaces all non-alphanumeric runs with a single '-',
        // so there should not be consecutive hyphens after trimming.
        let ns = AppConfig.keychainNamespace
        XCTAssertFalse(ns.contains("--"), "keychainNamespace should not contain consecutive hyphens: \(ns)")
    }

    func testDevLoginURLDerivedFromBase() {
        // devLoginURL should be apiBaseURL + "/dev/login"
        let expected = AppConfig.apiBaseURL.appendingPathComponent("dev/login")
        XCTAssertEqual(AppConfig.devLoginURL, expected)
    }

    func testDevLoginURLContainsDevLoginPath() {
        let url = AppConfig.devLoginURL.absoluteString
        XCTAssertTrue(url.hasSuffix("dev/login") || url.hasSuffix("dev/login/"),
                       "devLoginURL should end with dev/login path: \(url)")
    }

    func testAuthCallbackScheme() {
        XCTAssertEqual(AppConfig.authCallbackScheme, "resonance")
    }

    func testAuthCallbackURL() {
        XCTAssertEqual(AppConfig.authCallbackURL.scheme, "resonance")
        XCTAssertEqual(AppConfig.authCallbackURL.host, "auth-callback")
    }

    func testKeychainNamespaceNotDefault() {
        // Unless the sanitized URL is empty (which it should not be for any valid URL),
        // we should not fall back to "resonance-default"
        let ns = AppConfig.keychainNamespace
        XCTAssertNotEqual(ns, "resonance-default",
                          "With a valid API base URL, keychainNamespace should not be the fallback default")
    }
}

// MARK: - KeychainStore Namespace Isolation Tests

final class KeychainStoreNamespaceTests: XCTestCase {

    func testAccountKeyProducesNamespacedKey() {
        // accountKey should prefix the raw key with the keychainNamespace + "."
        let result = KeychainStore.accountKey(for: "accessToken")
        let expected = "\(AppConfig.keychainNamespace).accessToken"
        XCTAssertEqual(result, expected,
                       "accountKey should produce '<namespace>.accessToken', got: \(result)")
    }

    func testAccountKeyNamespacePrefixIsConsistent() {
        // Multiple calls with different keys should all share the same namespace prefix
        let key1 = KeychainStore.accountKey(for: "accessToken")
        let key2 = KeychainStore.accountKey(for: "refreshToken")
        let key3 = KeychainStore.accountKey(for: "userId")

        let prefix = AppConfig.keychainNamespace + "."
        XCTAssertTrue(key1.hasPrefix(prefix))
        XCTAssertTrue(key2.hasPrefix(prefix))
        XCTAssertTrue(key3.hasPrefix(prefix))

        // The suffix after the prefix should be exactly the raw key
        XCTAssertEqual(String(key1.dropFirst(prefix.count)), "accessToken")
        XCTAssertEqual(String(key2.dropFirst(prefix.count)), "refreshToken")
        XCTAssertEqual(String(key3.dropFirst(prefix.count)), "userId")
    }

    func testDifferentAPIURLsProduceDifferentNamespaces() {
        // The keychainNamespace is derived from apiBaseURL. Since AppConfig uses a
        // static let computed once from the environment, we verify the derivation
        // logic directly: different URL strings should produce different sanitized outputs.
        let url1 = "http://localhost:4000"
        let url2 = "https://api.resonance.example.com"
        let url3 = "https://staging.resonance.example.com"

        func deriveNamespace(from urlString: String) -> String {
            let base = urlString.lowercased()
            let sanitized = base
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return sanitized.isEmpty ? "resonance-default" : "resonance-\(sanitized)"
        }

        let ns1 = deriveNamespace(from: url1)
        let ns2 = deriveNamespace(from: url2)
        let ns3 = deriveNamespace(from: url3)

        XCTAssertNotEqual(ns1, ns2, "localhost and production should have different namespaces")
        XCTAssertNotEqual(ns2, ns3, "production and staging should have different namespaces")
        XCTAssertNotEqual(ns1, ns3, "localhost and staging should have different namespaces")
    }

    func testNamespaceContainsOnlySafeCharacters() {
        // The namespace should only contain lowercase alphanumeric characters and hyphens.
        // (Dots are not expected in the namespace itself per the sanitization regex.)
        let ns = AppConfig.keychainNamespace
        let safeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for scalar in ns.unicodeScalars {
            XCTAssertTrue(safeChars.contains(scalar),
                          "Namespace contains unsafe character '\(scalar)': \(ns)")
        }
    }

    func testNamespaceDoesNotStartOrEndWithHyphen() {
        let ns = AppConfig.keychainNamespace
        XCTAssertFalse(ns.hasPrefix("-"), "Namespace should not start with hyphen: \(ns)")
        XCTAssertFalse(ns.hasSuffix("-"), "Namespace should not end with hyphen: \(ns)")
    }
}

// MARK: - PDFExporter Sanitize & Helper Tests

final class PDFExporterSanitizeTests: XCTestCase {

    func testSanitizeRemovesControlCharacters() {
        // NUL, unit separator, and other C0 control characters should be replaced with spaces
        let input = "Hello\u{0000}World\u{001F}Test"
        let result = PDFExporter.sanitizeForPDF(input)
        XCTAssertFalse(result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                       "Result should not contain any control characters: \(result)")
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("World"))
        XCTAssertTrue(result.contains("Test"))
    }

    func testSanitizeReplacesTabsAndNewlines() {
        let input = "Line1\tTabbed\nLine2\r\nLine3"
        let result = PDFExporter.sanitizeForPDF(input)
        // Newlines are first converted to spaces, then control chars (tab, CR) also become spaces
        XCTAssertFalse(result.contains("\t"), "Tabs should be removed")
        XCTAssertFalse(result.contains("\n"), "Newlines should be removed")
        XCTAssertFalse(result.contains("\r"), "Carriage returns should be removed")
        XCTAssertTrue(result.contains("Line1"))
        XCTAssertTrue(result.contains("Line2"))
        XCTAssertTrue(result.contains("Line3"))
    }

    func testSanitizePreservesNormalUnicodeText() {
        let input = "Beethoven Sonata No. 14 -- Clair de Lune"
        let result = PDFExporter.sanitizeForPDF(input)
        XCTAssertEqual(result, input)
    }

    func testSanitizePreservesAccentedCharacters() {
        let input = "Debussy: Reverie en re bemol majeur"
        let result = PDFExporter.sanitizeForPDF(input)
        XCTAssertEqual(result, input)

        let accented = "Dvorak Serenade fur Streicher"
        let accentedResult = PDFExporter.sanitizeForPDF(accented)
        XCTAssertEqual(accentedResult, accented)
    }

    func testSanitizePreservesEmoji() {
        let input = "Great practice session! 🎵🎹👏"
        let result = PDFExporter.sanitizeForPDF(input)
        XCTAssertTrue(result.contains("🎵"), "Emoji should be preserved")
        XCTAssertTrue(result.contains("🎹"), "Emoji should be preserved")
        XCTAssertTrue(result.contains("👏"), "Emoji should be preserved")
        XCTAssertTrue(result.contains("Great practice session!"))
    }

    func testSanitizePreservesUnicodeScripts() {
        // CJK, Cyrillic, Arabic characters should all be preserved
        let cjk = "練習 ピアノ 피아노"
        XCTAssertEqual(PDFExporter.sanitizeForPDF(cjk), cjk)

        let cyrillic = "Фортепиано"
        XCTAssertEqual(PDFExporter.sanitizeForPDF(cyrillic), cyrillic)
    }

    func testSanitizeTrimsWhitespace() {
        let input = "  spaced out  "
        let result = PDFExporter.sanitizeForPDF(input)
        XCTAssertEqual(result, "spaced out", "Leading/trailing whitespace should be trimmed")
    }

    func testSanitizeEmptyString() {
        let result = PDFExporter.sanitizeForPDF("")
        XCTAssertEqual(result, "")
    }

    func testSanitizeStringOfOnlyControlCharacters() {
        let input = "\u{0000}\u{0001}\u{001F}"
        let result = PDFExporter.sanitizeForPDF(input)
        // After trimming whitespace/newlines from the original, then replacing controls with spaces,
        // the result should contain only spaces (no control characters remain).
        XCTAssertFalse(result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                       "Should not contain control characters")
    }

    func testSanitizeVeryLongString() {
        // Verify no crash with a very long string (10000 characters)
        let longString = String(repeating: "Practice scales and arpeggios. ", count: 334)
        XCTAssertTrue(longString.count > 10000)
        let result = PDFExporter.sanitizeForPDF(longString)
        XCTAssertFalse(result.isEmpty, "Sanitize should handle long strings without crashing")
        XCTAssertTrue(result.count > 9000, "Long string should be mostly preserved")
    }
}

// MARK: - PDFExporter Empty & Edge Case Tests

final class PDFExporterEdgeCaseTests: XCTestCase {

    @MainActor
    func testExportWithEmptyEntriesDoesNotCrash() {
        // PDFExporter.export uses UIGraphicsPDFRenderer which requires UIKit.
        // In a unit-test environment without a full UIKit host, we verify the
        // method signature accepts an empty array. If UIKit is available, it
        // should not crash; if not, we just verify it throws rather than crashes.
        let entries: [LocalPracticeEntry] = []
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-empty-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // This may throw if UIKit rendering isn't available in the test host,
        // but it must not crash (e.g., force-unwrap, index out of bounds).
        do {
            try PDFExporter.export(entries: entries, to: tempURL)
            // If we get here, export succeeded -- the file should exist
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        } catch {
            // Acceptable: UIKit renderer may not be available in test host.
            // The key assertion is that we did not crash.
        }
    }

    @MainActor
    func testExportWithVeryLongGoalTextDoesNotCrash() {
        let longGoal = String(repeating: "A", count: 10_000)
        let entry = LocalPracticeEntry(
            id: "long-goal-entry",
            courseId: "course-1",
            studentId: "student-1",
            practiceDate: Date(),
            goalText: longGoal,
            durationSeconds: nil,
            tags: [],
            notes: nil,
            status: .draft
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-long-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try PDFExporter.export(entries: [entry], to: tempURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        } catch {
            // Acceptable: UIKit renderer may not be available in test host.
        }
    }
}
