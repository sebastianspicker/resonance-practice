import XCTest
import Foundation
import SwiftData
@testable import ResonanceApp

// Purpose: verifies queue coalescing, ownership isolation, and cross-service workflow regressions.

final class SyncQueueCoalescingTests: XCTestCase {
    private struct OnlineSyncFixture {
        let container: ModelContainer
        let authManager: AuthManager
        let syncManager: SyncManager
    }

    @MainActor
    private func makeAuthenticatedAuthManager(
        apiClient: APIClient,
        userId: String,
        displayName: String
    ) -> AuthManager {
        let authManager = AuthManager(apiClient: apiClient, removeSessionData: {})
        authManager.session = AuthSession(
            accessToken: makeUnexpiredJWT(),
            refreshToken: "refresh-token",
            userId: userId,
            displayName: displayName,
            globalRole: "student"
        )
        return authManager
    }

    @MainActor
    private func makeOnlineSyncManager(
        userId: String,
        displayName: String,
        apiClient: APIClient = APIClient(),
        verifiedOwner: @escaping () throws -> String?,
        processItemOverride: @escaping @MainActor (SyncQueueItem, String) async throws -> Void
    ) -> OnlineSyncFixture {
        let container = PersistenceController.createContainer(inMemory: true)
        let authManager = makeAuthenticatedAuthManager(
            apiClient: apiClient, userId: userId, displayName: displayName
        )
        let networkMonitor = NetworkMonitor()
        networkMonitor.isOnline = true
        let syncManager = SyncManager(
            modelContext: container.mainContext,
            authManager: authManager,
            apiClient: apiClient,
            networkMonitor: networkMonitor,
            verifiedOwner: verifiedOwner,
            processItemOverride: processItemOverride
        )
        return OnlineSyncFixture(
            container: container,
            authManager: authManager,
            syncManager: syncManager
        )
    }

    @MainActor
    private func makeStudentSyncManager(
        processItemOverride: @escaping @MainActor (SyncQueueItem, String) async throws -> Void
    ) -> OnlineSyncFixture {
        makeOnlineSyncManager(
            userId: "student-1",
            displayName: "Student",
            verifiedOwner: { "student-1" },
            processItemOverride: processItemOverride
        )
    }

    @MainActor
    func testProfileConflictNeverSendsOrMutatesPreviousOwnersQueue() async throws {
        var sentItemIDs: [String] = []
        let fixture = makeOnlineSyncManager(
            userId: "user-b",
            displayName: "User B",
            verifiedOwner: { "user-a" },
            processItemOverride: { item, _ in sentItemIDs.append(item.id) }
        )
        let otherUserItem = SyncQueueItem(
            id: "user-a-work",
            type: SyncTaskType.createEntry.rawValue,
            payloadJSON: "{\"entryId\":\"entry-a\"}",
            ownerId: "user-a"
        )
        fixture.container.mainContext.insert(otherUserItem)
        try fixture.container.mainContext.save()

        await fixture.syncManager.processQueue()

        XCTAssertTrue(sentItemIDs.isEmpty)
        let remaining = try fixture.container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(remaining.map(\.id), ["user-a-work"])
        XCTAssertEqual(remaining.first?.ownerId, "user-a")
    }

    @MainActor
    func testInvalidationPreventsAnInFlightResponseFromDeletingQueueWork() async throws {
        let started = expectation(description: "request started")
        var release: CheckedContinuation<Void, Never>?
        let fixture = makeOnlineSyncManager(
            userId: "user-a",
            displayName: "User A",
            verifiedOwner: { "user-a" },
            processItemOverride: { _, _ in
                started.fulfill()
                await withCheckedContinuation { release = $0 }
            }
        )
        fixture.syncManager.enqueue(type: .createEntry, payload: ["entryId": "entry-a"])

        let processingTask = Task { await fixture.syncManager.processQueue() }
        await fulfillment(of: [started], timeout: 1)
        fixture.syncManager.invalidateProcessing()
        release?.resume()
        await processingTask.value

        let remaining = try fixture.container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.status, SyncStatus.pending.rawValue)
    }

    @MainActor
    func testProcessQueueCoalescesConcurrentTriggersAndProcessesNewItemsOnce() async throws {
        let firstItemStarted = expectation(description: "first item started")
        var releaseFirstItem: CheckedContinuation<Void, Never>?
        var processedEntryIds: [String] = []
        let fixture = makeStudentSyncManager(
            processItemOverride: { item, _ in
                let payloadData = try XCTUnwrap(item.payloadJSON.data(using: .utf8))
                let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
                processedEntryIds.append(try XCTUnwrap(payload["entryId"] as? String))

                if processedEntryIds.count == 1 {
                    firstItemStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        releaseFirstItem = continuation
                    }
                }
            }
        )

        fixture.syncManager.enqueue(type: .createEntry, payload: ["entryId": "entry-1"])

        let firstTask = Task { await fixture.syncManager.processQueue() }
        await fulfillment(of: [firstItemStarted], timeout: 1.0)

        fixture.syncManager.enqueue(type: .createEntry, payload: ["entryId": "entry-2"])
        let secondTask = Task { await fixture.syncManager.processQueue() }

        releaseFirstItem?.resume()
        await firstTask.value
        await secondTask.value

        let remainingItems = try fixture.container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertTrue(remainingItems.isEmpty)
        XCTAssertEqual(processedEntryIds, ["entry-1", "entry-2"])
        XCTAssertEqual(Set(processedEntryIds).count, 2)
        XCTAssertEqual(fixture.syncManager.pendingQueueCount, 0)
        XCTAssertEqual(fixture.syncManager.failedQueueCount, 0)
    }

    @MainActor
    func testInvalidSessionLeavesWorkPendingAndSignsOutWithoutRetryChurn() async throws {
        let logoutRequested = expectation(description: "server logout requested")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/auth/logout")
            logoutRequested.fulfill()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{\"success\":true}".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let apiClient = APIClient(session: URLSession(configuration: configuration))
        let fixture = makeOnlineSyncManager(
            userId: "student-1",
            displayName: "Student",
            apiClient: apiClient,
            verifiedOwner: { "student-1" },
            processItemOverride: { _, _ in
                throw APIError(
                    error: APIError.APIErrorBody(
                        code: "INVALID_TOKEN",
                        message: "Expired",
                        details: nil
                    )
                )
            }
        )
        fixture.syncManager.enqueue(type: .createEntry, payload: ["entryId": "entry-auth-boundary"])

        await fixture.syncManager.processQueue()

        let items = try fixture.container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.status, SyncStatus.pending.rawValue)
        XCTAssertEqual(item.retryCount, 0)
        XCTAssertEqual(item.lastError, "INVALID_TOKEN")
        XCTAssertNil(fixture.authManager.session)
        await fulfillment(of: [logoutRequested], timeout: 1)
    }

    @MainActor
    func testRetryableFailureStopsThePassBeforeDependentLaterItem() async throws {
        var executedTypes: [String] = []
        let fixture = makeStudentSyncManager(
            processItemOverride: { item, _ in
                executedTypes.append(item.type)
                if item.type == SyncTaskType.createEntry.rawValue {
                    throw URLError(.timedOut)
                }
            }
        )
        let first = SyncQueueItem(
            id: "create-first",
            type: SyncTaskType.createEntry.rawValue,
            payloadJSON: "{\"entryId\":\"entry-1\"}",
            ownerId: "student-1"
        )
        first.createdAt = Date(timeIntervalSince1970: 1)
        let dependent = SyncQueueItem(
            id: "artifact-second",
            type: SyncTaskType.syncArtifact.rawValue,
            payloadJSON: "{\"artifactId\":\"artifact-1\",\"entryId\":\"entry-1\"}",
            ownerId: "student-1"
        )
        dependent.createdAt = Date(timeIntervalSince1970: 2)
        fixture.container.mainContext.insert(first)
        fixture.container.mainContext.insert(dependent)
        try fixture.container.mainContext.save()

        await fixture.syncManager.processQueue()

        XCTAssertEqual(executedTypes, [SyncTaskType.createEntry.rawValue])
        XCTAssertEqual(first.status, SyncStatus.pending.rawValue)
        XCTAssertEqual(first.retryCount, 1)
        XCTAssertNotNil(first.nextAttemptAt)
        XCTAssertEqual(dependent.status, SyncStatus.pending.rawValue)
        XCTAssertEqual(dependent.retryCount, 0)
    }

    @MainActor
    func testArtifactWorkReservesItsParentEntryInCommandWaves() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let entry = LocalPracticeEntry(
            id: "entry-artifact-barrier",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(
                practiceDate: Date(),
                goalText: "Upload before submit",
                durationSeconds: nil,
                tags: [],
                notes: nil
            ),
            status: .draft
        )
        let artifact = LocalArtifact(
            id: "artifact-barrier",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 30,
            localPath: "/tmp/artifact-barrier.m4a"
        )
        entry.artifacts.append(artifact)
        container.mainContext.insert(entry)
        container.mainContext.insert(artifact)
        try container.mainContext.save()
        let executor = makeTaskExecutor(for: container.mainContext)
        let item = SyncQueueItem(
            id: "artifact-operation",
            type: SyncTaskType.syncArtifact.rawValue,
            payloadJSON: "{\"artifactId\":\"\(artifact.id)\"}"
        )

        XCTAssertEqual(try executor.commandEntityID(for: item), entry.id)
        XCTAssertNil(try executor.command(for: item))
    }
}

final class CalendarRefreshSafetyTests: XCTestCase {
    private struct CalendarRefreshFixture {
        let container: ModelContainer
        let url: URL
        let service: CalendarService
    }

    @MainActor
    func testNon200ResponseDoesNotClearExistingEvents() async throws {
        let fixture = makeCalendarRefreshFixture(statusCode: 500, data: Data())

        try await assertExistingEventSurvivesRefreshFailure(
            service: fixture.service,
            url: fixture.url,
            container: fixture.container
        ) { error in
            XCTAssertEqual(error.errorDescription, "Calendar server returned HTTP 500")
        }
    }

    @MainActor
    func testMalformedContentDoesNotClearExistingEvents() async throws {
        let fixture = makeCalendarRefreshFixture(
            statusCode: 200,
            data: Data("not-an-ical-feed".utf8)
        )

        try await assertExistingEventSurvivesRefreshFailure(
            service: fixture.service,
            url: fixture.url,
            container: fixture.container
        ) { error in
            XCTAssertEqual(error, .invalidCalendarData)
        }
    }

    @MainActor
    func testValidContentReplacesExistingEventsDeterministically() async throws {
        let ical = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:new-event
        SUMMARY:Lesson
        DTSTART:20250101T120000Z
        DTEND:20250101T130000Z
        LOCATION:Studio A
        END:VEVENT
        END:VCALENDAR
        """
        let fixture = makeCalendarRefreshFixture(statusCode: 200, data: Data(ical.utf8))

        try await fixture.service.refresh(from: fixture.url, modelContext: fixture.container.mainContext)

        let events = try fixture.container.mainContext.fetch(FetchDescriptor<CalendarEvent>())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, "new-event")
        XCTAssertEqual(events.first?.summary, "Lesson")
    }

    @MainActor
    func testOversizedCalendarContentDoesNotClearExistingEvents() async throws {
        let oversized = "BEGIN:VCALENDAR\n" + String(repeating: "A", count: 1_048_577)
        let fixture = makeCalendarRefreshFixture(statusCode: 200, data: Data(oversized.utf8))

        do {
            try await fixture.service.refresh(from: fixture.url, modelContext: fixture.container.mainContext)
            XCTFail("Expected refresh to throw for oversized calendar content")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .calendarDataTooLarge)
        }

        let events = try fixture.container.mainContext.fetch(FetchDescriptor<CalendarEvent>())
        XCTAssertEqual(events.map(\.id), ["existing"])
    }

    @MainActor
    private func insertCalendarEvent(id: String, into modelContext: ModelContext) {
        let event = CalendarEvent(
            id: id,
            summary: "Existing Event",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_600),
            location: nil
        )
        modelContext.insert(event)
        try? modelContext.save()
    }

    @MainActor
    private func makeCalendarRefreshFixture(statusCode: Int, data: Data) -> CalendarRefreshFixture {
        let container = PersistenceController.createContainer(inMemory: true)
        insertCalendarEvent(id: "existing", into: container.mainContext)
        let url = URL(string: "https://calendar.example.test/feed.ics")!
        let service = CalendarService(session: makeSession(for: url) { _ in
            (HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!, data)
        })
        return CalendarRefreshFixture(container: container, url: url, service: service)
    }

    @MainActor
    private func assertRefreshFailure(
        service: CalendarService,
        url: URL,
        context: ModelContext,
        assertion: (CalendarError) -> Void
    ) async throws {
        do {
            try await service.refresh(from: url, modelContext: context)
            XCTFail("Expected calendar refresh to throw")
        } catch let error as CalendarError {
            assertion(error)
        }
    }

    @MainActor
    private func assertExistingEventSurvivesRefreshFailure(
        service: CalendarService,
        url: URL,
        container: ModelContainer,
        assertion: (CalendarError) -> Void
    ) async throws {
        try await assertRefreshFailure(service: service, url: url, context: container.mainContext, assertion: assertion)
        let events = try container.mainContext.fetch(FetchDescriptor<CalendarEvent>())
        XCTAssertEqual(events.map(\.id), ["existing"])
    }

    private func makeSession(
        for expectedURL: URL,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            return try handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class EntryReconciliationPendingWorkTests: XCTestCase {
    override func tearDown() {
        EntryReconciliationURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testPendingCaptureProfileSurvivesStaleRemoteRefresh() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let context = container.mainContext
        let baseline = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let entry = makePendingCaptureProfileEntry(baseline: baseline)
        context.insert(entry)
        enqueueCaptureProfileSync(for: entry, in: context)
        try context.save()

        let expectedURL = AppConfig.apiV1URL(path: "courses/course-1/entries")
        EntryReconciliationURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, expectedURL.path)
            let response = self.staleRemoteEntryListData()
            let url = try XCTUnwrap(request.url)
            let httpResponse = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (
                httpResponse,
                response
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EntryReconciliationURLProtocol.self]

        try await EntryReconciliationService(
            modelContext: context,
            apiClient: APIClient(session: URLSession(configuration: configuration))
        ).refresh(courseId: "course-1", accessToken: "access-token")

        XCTAssertEqual(entry.captureProfile, .ensembleGroup)
        XCTAssertEqual(entry.updatedAt, baseline)
    }

    private func makePendingCaptureProfileEntry(baseline: Date) -> LocalPracticeEntry {
        let entry = LocalPracticeEntry(
            id: "entry-pending-profile",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(
                practiceDate: baseline,
                goalText: "Teach phrasing",
                durationSeconds: nil,
                tags: ["lesson"],
                notes: nil
            ),
            status: .draft,
            captureContext: CaptureContext(
                kind: .teachingLesson,
                consentConfirmedAt: baseline,
                consentScope: .privateCourseReview,
                captureProfile: .ensembleGroup
            )
        )
        entry.remoteUpdatedAt = baseline
        entry.updatedAt = baseline
        return entry
    }

    private func enqueueCaptureProfileSync(for entry: LocalPracticeEntry, in context: ModelContext) {
        context.insert(
            SyncQueueItem(
                id: UUID().uuidString,
                type: SyncTaskType.syncCaptureProfile.rawValue,
                payloadJSON: "{\"entryId\":\"\(entry.id)\"}"
            )
        )
    }

    private func staleRemoteEntryListData() -> Data {
        Data(
            """
            {
              "items": [
                {
                  "id": "entry-pending-profile",
                  "courseId": "course-1",
                  "studentId": "student-1",
                  "kind": "teaching_lesson",
                  "practiceDate": "2026-01-01T12:00:00Z",
                  "goalText": "Teach phrasing",
                  "durationSeconds": null,
                  "tags": ["lesson"],
                  "notes": null,
                  "status": "draft",
                  "consentConfirmedAt": "2026-01-01T12:00:00Z",
                  "consentScope": "private_course_review",
                  "captureProfile": "teacher_learner",
                  "captureMarkers": [],
                  "artifacts": [],
                  "createdAt": "2026-01-01T12:00:00Z",
                  "updatedAt": "2026-01-01T12:00:00Z"
                }
              ],
              "nextCursor": null
            }
            """.utf8
        )
    }
}

final class RemoteArtifactPlaybackSourceTests: XCTestCase {
    override func tearDown() {
        ArtifactPlaybackURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testReconciledRemoteArtifactUsesAuthenticatedDownloadURLWhenLocalPathIsEmpty() async throws {
        let artifact = LocalArtifact(
            id: "artifact-remote-only",
            entryId: "entry-1",
            type: .audio,
            durationSeconds: 30,
            localPath: ""
        )
        let expectedURL = AppConfig.apiV1URL(path: "artifacts/\(artifact.id)/download-session")
        ArtifactPlaybackURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            let data = Data(
                "{\"downloadUrl\":\"https://storage.example.test/artifact-remote-only\",\"expiresInSeconds\":900}".utf8
            )
            let response = try XCTUnwrap(
                HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtifactPlaybackURLProtocol.self]

        let sourceURL = try await ArtifactPlaybackSourceResolver(
            apiClient: APIClient(session: URLSession(configuration: configuration))
        ).resolve(artifact: artifact, accessToken: "access-token")

        XCTAssertEqual(sourceURL.absoluteString, "https://storage.example.test/artifact-remote-only")
        XCTAssertFalse(sourceURL.isFileURL)
    }
}

final class SubmitEntryStateTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testSubmitEntryMarksLocalEntrySubmittedOnlyAfterServerSuccess() async throws {
        let (container, entry) = try makeStoredSubmittableEntry(id: "entry-submit-success")
        let modelContext = container.mainContext

        installSubmitResponse(for: entry, statusCode: 200, data: submitEntryResponseJSON(id: entry.id, status: "submitted"))

        let executor = makeSubmitExecutor(modelContext: modelContext)
        let item = makeSubmitQueueItem(entryId: entry.id)

        try await executor.execute(item: item, accessToken: "access-token")

        XCTAssertEqual(entry.status, .submitted)
    }

    @MainActor
    func testSubmitEntryFailureLeavesLocalEntryDraft() async throws {
        let (container, entry) = try makeStoredSubmittableEntry(id: "entry-submit-rejected")
        let modelContext = container.mainContext

        let body = Data(
                """
                {
                    "error": {
                        "code": "ARTIFACTS_NOT_UPLOADED",
                        "message": "All artifacts must be uploaded before submitting"
                    }
                }
                """.utf8
            )
        installSubmitResponse(for: entry, statusCode: 409, data: body)

        let executor = makeSubmitExecutor(modelContext: modelContext)
        let item = makeSubmitQueueItem(entryId: entry.id)

        do {
            try await executor.execute(item: item, accessToken: "access-token")
            XCTFail("Expected submit to throw the server rejection")
        } catch let error as APIError {
            XCTAssertEqual(error.error.code, "ARTIFACTS_NOT_UPLOADED")
        }

        XCTAssertEqual(entry.status, .draft)
    }

    @MainActor
    func testSubmitEntryReconcilesSubmittedStateAfterLockedRetry() async throws {
        let (container, entry) = try makeStoredSubmittableEntry(id: "entry-submit-locked")
        let modelContext = container.mainContext

        let submitURL = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entry.id)/submit")
        let entryURL = AppConfig.apiV1URL(path: "entries/\(entry.id)")
        MockURLProtocol.requestHandler = { request in
            if request.url == submitURL {
                XCTAssertEqual(request.httpMethod, "POST")
                return (
                    HTTPURLResponse(url: submitURL, statusCode: 409, httpVersion: nil, headerFields: nil)!,
                    Data("{\"error\":{\"code\":\"ENTRY_LOCKED\",\"message\":\"Only draft entries can be submitted\"}}".utf8)
                )
            }
            XCTAssertEqual(request.url, entryURL)
            XCTAssertEqual(request.httpMethod, "GET")
            return (
                HTTPURLResponse(url: entryURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                submitEntryResponseJSON(id: entry.id, status: "submitted")
            )
        }

        try await makeSubmitExecutor(modelContext: modelContext).execute(
            item: makeSubmitQueueItem(entryId: entry.id),
            accessToken: "access-token"
        )

        XCTAssertEqual(entry.status, .submitted)
    }

    @MainActor
    private func makeSubmitExecutor(modelContext: ModelContext) -> TaskExecutor {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return TaskExecutor(
            apiClient: APIClient(session: URLSession(configuration: configuration)),
            store: QueueStore(modelContext: modelContext),
            session: URLSession(configuration: .ephemeral)
        )
    }

    @MainActor
    private func installSubmitResponse(for entry: LocalPracticeEntry, statusCode: Int, data: Data) {
        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entry.id)/submit")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.httpMethod, "POST")
            return (
                HTTPURLResponse(url: expectedURL, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
    }

    private func makeSubmittableEntry(id: String) -> LocalPracticeEntry {
        let entry = LocalPracticeEntry(
            id: id,
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(
                practiceDate: Date(timeIntervalSince1970: 1_771_848_000),
                goalText: "Submitted only after server success",
                durationSeconds: nil,
                tags: ["tone"],
                notes: nil
            ),
            status: .draft
        )
        let artifact = LocalArtifact(
            id: "\(id)-artifact",
            entryId: id,
            type: .audio,
            durationSeconds: 30,
            localPath: "/tmp/\(id).m4a"
        )
        artifact.uploadState = .uploaded
        artifact.syncPhase = .uploaded
        entry.artifacts.append(artifact)
        return entry
    }

    @MainActor
    private func makeStoredSubmittableEntry(id: String) throws -> (ModelContainer, LocalPracticeEntry) {
        let container = PersistenceController.createContainer(inMemory: true)
        let entry = makeSubmittableEntry(id: id)
        container.mainContext.insert(entry)
        try container.mainContext.save()
        return (container, entry)
    }

    private func makeSubmitQueueItem(entryId: String) -> SyncQueueItem {
        guard let data = try? JSONSerialization.data(withJSONObject: ["entryId": entryId]) else {
            preconditionFailure("A string-only submission payload must be JSON-serializable")
        }
        guard let payloadJSON = String(bytes: data, encoding: .utf8) else {
            preconditionFailure("A JSON submission payload must be valid UTF-8")
        }
        return SyncQueueItem(
            id: "\(entryId)-submit",
            type: SyncTaskType.submitEntry.rawValue,
            payloadJSON: payloadJSON
        )
    }
}
