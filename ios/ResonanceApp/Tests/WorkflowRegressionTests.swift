import XCTest
import Foundation
import SwiftData
@testable import ResonanceApp

final class SyncQueueCoalescingTests: XCTestCase {
    @MainActor
    func testProcessQueueCoalescesConcurrentTriggersAndProcessesNewItemsOnce() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let apiClient = APIClient()
        let authManager = AuthManager(apiClient: apiClient, removeSessionData: {})
        authManager.session = AuthSession(
            accessToken: makeUnexpiredJWT(),
            refreshToken: "refresh-token",
            userId: "student-1",
            displayName: "Student",
            globalRole: "student"
        )
        let networkMonitor = NetworkMonitor()
        networkMonitor.isOnline = true

        let firstItemStarted = expectation(description: "first item started")
        var releaseFirstItem: CheckedContinuation<Void, Never>?
        var processedEntryIds: [String] = []

        let syncManager = SyncManager(
            modelContext: container.mainContext,
            authManager: authManager,
            apiClient: apiClient,
            networkMonitor: networkMonitor,
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

        syncManager.enqueue(type: .createEntry, payload: ["entryId": "entry-1"])

        let firstTask = Task { await syncManager.processQueue() }
        await fulfillment(of: [firstItemStarted], timeout: 1.0)

        syncManager.enqueue(type: .createEntry, payload: ["entryId": "entry-2"])
        let secondTask = Task { await syncManager.processQueue() }

        releaseFirstItem?.resume()
        await firstTask.value
        await secondTask.value

        let remainingItems = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertTrue(remainingItems.isEmpty)
        XCTAssertEqual(processedEntryIds, ["entry-1", "entry-2"])
        XCTAssertEqual(Set(processedEntryIds).count, 2)
        XCTAssertEqual(syncManager.pendingQueueCount, 0)
        XCTAssertEqual(syncManager.failedQueueCount, 0)
    }

    @MainActor
    func testInvalidSessionLeavesWorkPendingAndSignsOutWithoutRetryChurn() async throws {
        MockURLProtocol.requestHandler = { request in
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
        let container = PersistenceController.createContainer(inMemory: true)
        let authManager = AuthManager(apiClient: apiClient, removeSessionData: {})
        authManager.session = AuthSession(
            accessToken: makeUnexpiredJWT(),
            refreshToken: "refresh-token",
            userId: "student-1",
            displayName: "Student",
            globalRole: "student"
        )
        let networkMonitor = NetworkMonitor()
        networkMonitor.isOnline = true
        let syncManager = SyncManager(
            modelContext: container.mainContext,
            authManager: authManager,
            apiClient: apiClient,
            networkMonitor: networkMonitor,
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
        syncManager.enqueue(type: .createEntry, payload: ["entryId": "entry-auth-boundary"])

        await syncManager.processQueue()

        let items = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.status, SyncStatus.pending.rawValue)
        XCTAssertEqual(item.retryCount, 0)
        XCTAssertEqual(item.lastError, "INVALID_TOKEN")
        XCTAssertNil(authManager.session)
    }

    @MainActor
    func testRetryableFailureStopsThePassBeforeDependentLaterItem() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let apiClient = APIClient()
        let authManager = AuthManager(apiClient: apiClient)
        authManager.session = AuthSession(
            accessToken: makeUnexpiredJWT(),
            refreshToken: "refresh-token",
            userId: "student-1",
            displayName: "Student",
            globalRole: "student"
        )
        let networkMonitor = NetworkMonitor()
        networkMonitor.isOnline = true
        var executedTypes: [String] = []
        let syncManager = SyncManager(
            modelContext: container.mainContext,
            authManager: authManager,
            apiClient: apiClient,
            networkMonitor: networkMonitor,
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
            payloadJSON: "{\"entryId\":\"entry-1\"}"
        )
        first.createdAt = Date(timeIntervalSince1970: 1)
        let dependent = SyncQueueItem(
            id: "artifact-second",
            type: SyncTaskType.syncArtifact.rawValue,
            payloadJSON: "{\"artifactId\":\"artifact-1\",\"entryId\":\"entry-1\"}"
        )
        dependent.createdAt = Date(timeIntervalSince1970: 2)
        container.mainContext.insert(first)
        container.mainContext.insert(dependent)
        try container.mainContext.save()

        await syncManager.processQueue()

        XCTAssertEqual(executedTypes, [SyncTaskType.createEntry.rawValue])
        XCTAssertEqual(first.status, SyncStatus.pending.rawValue)
        XCTAssertEqual(first.retryCount, 1)
        XCTAssertNotNil(first.nextAttemptAt)
        XCTAssertEqual(dependent.status, SyncStatus.pending.rawValue)
        XCTAssertEqual(dependent.retryCount, 0)
    }
}

final class CalendarRefreshSafetyTests: XCTestCase {
    @MainActor
    func testNon200ResponseDoesNotClearExistingEvents() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        insertCalendarEvent(id: "existing", into: container.mainContext)

        let url = URL(string: "https://calendar.example.test/feed.ics")!
        let service = CalendarService(session: makeSession(for: url) { _ in
            (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        })

        do {
            try await service.refresh(from: url, modelContext: container.mainContext)
            XCTFail("Expected refresh to throw for non-200 response")
        } catch let error as CalendarError {
            XCTAssertEqual(error.errorDescription, "Calendar server returned HTTP 500")
        }

        let events = try container.mainContext.fetch(FetchDescriptor<CalendarEvent>())
        XCTAssertEqual(events.map(\.id), ["existing"])
    }

    @MainActor
    func testMalformedContentDoesNotClearExistingEvents() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        insertCalendarEvent(id: "existing", into: container.mainContext)

        let url = URL(string: "https://calendar.example.test/feed.ics")!
        let service = CalendarService(session: makeSession(for: url) { _ in
            (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("not-an-ical-feed".utf8))
        })

        do {
            try await service.refresh(from: url, modelContext: container.mainContext)
            XCTFail("Expected refresh to throw for malformed calendar content")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .invalidCalendarData)
        }

        let events = try container.mainContext.fetch(FetchDescriptor<CalendarEvent>())
        XCTAssertEqual(events.map(\.id), ["existing"])
    }

    @MainActor
    func testValidContentReplacesExistingEventsDeterministically() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        insertCalendarEvent(id: "existing", into: container.mainContext)

        let url = URL(string: "https://calendar.example.test/feed.ics")!
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
        let service = CalendarService(session: makeSession(for: url) { _ in
            (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(ical.utf8))
        })

        try await service.refresh(from: url, modelContext: container.mainContext)

        let events = try container.mainContext.fetch(FetchDescriptor<CalendarEvent>())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, "new-event")
        XCTAssertEqual(events.first?.summary, "Lesson")
    }

    @MainActor
    func testOversizedCalendarContentDoesNotClearExistingEvents() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        insertCalendarEvent(id: "existing", into: container.mainContext)

        let url = URL(string: "https://calendar.example.test/feed.ics")!
        let oversized = "BEGIN:VCALENDAR\n" + String(repeating: "A", count: 1_048_577)
        let service = CalendarService(session: makeSession(for: url) { _ in
            (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(oversized.utf8))
        })

        do {
            try await service.refresh(from: url, modelContext: container.mainContext)
            XCTFail("Expected refresh to throw for oversized calendar content")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .calendarDataTooLarge)
        }

        let events = try container.mainContext.fetch(FetchDescriptor<CalendarEvent>())
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

        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("courses/course-1/entries")
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
        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("artifacts/\(artifact.id)/download")
        ArtifactPlaybackURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            let data = try XCTUnwrap(
                "{\"downloadUrl\":\"https://storage.example.test/artifact-remote-only\",\"expiresInSeconds\":900}"
                    .data(using: .utf8)
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
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeSubmittableEntry(id: "entry-submit-success")
        modelContext.insert(entry)
        try modelContext.save()

        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entry.id)/submit")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.httpMethod, "POST")
            return (
                HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                submitEntryResponseJSON(id: entry.id, status: "submitted")
            )
        }

        let executor = makeSubmitExecutor(modelContext: modelContext)
        let item = makeSubmitQueueItem(entryId: entry.id)

        try await executor.execute(item: item, accessToken: "access-token")

        XCTAssertEqual(entry.status, .submitted)
    }

    @MainActor
    func testSubmitEntryFailureLeavesLocalEntryDraft() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeSubmittableEntry(id: "entry-submit-rejected")
        modelContext.insert(entry)
        try modelContext.save()

        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entry.id)/submit")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.httpMethod, "POST")
            let body = """
            {
                "error": {
                    "code": "ARTIFACTS_NOT_UPLOADED",
                    "message": "All artifacts must be uploaded before submitting"
                }
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: expectedURL, statusCode: 409, httpVersion: nil, headerFields: nil)!,
                body
            )
        }

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
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeSubmittableEntry(id: "entry-submit-locked")
        modelContext.insert(entry)
        try modelContext.save()

        let submitURL = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entry.id)/submit")
        let entryURL = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entry.id)")
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

    private func makeSubmittableEntry(id: String) -> LocalPracticeEntry {
        let entry = LocalPracticeEntry(
            id: id,
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(practiceDate: Date(timeIntervalSince1970: 1_771_848_000), goalText: "Submitted only after server success", durationSeconds: nil, tags: ["tone"], notes: nil),
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

final class ArtifactSyncRecoveryTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testArtifactRetryReconcilesAlreadyUploadedRemoteArtifact() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let localFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-already-uploaded.m4a")
        try Data("audio".utf8).write(to: localFileURL)
        defer { try? FileManager.default.removeItem(at: localFileURL) }
        let (entry, artifact) = makeArtifactRetryFixture(localFileURL: localFileURL)
        modelContext.insert(entry)
        modelContext.insert(artifact)
        try modelContext.save()

        let createURL = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entry.id)/artifacts")
        let entryURL = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entry.id)")
        MockURLProtocol.requestHandler = { request in
            if request.url == createURL {
                return (
                    HTTPURLResponse(url: createURL, statusCode: 409, httpVersion: nil, headerFields: nil)!,
                    Data("{\"error\":{\"code\":\"ID_CONFLICT\",\"message\":\"Artifact already exists\"}}".utf8)
                )
            }
            XCTAssertEqual(request.url, entryURL)
            XCTAssertEqual(request.httpMethod, "GET")
            return (
                HTTPURLResponse(url: entryURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                entryResponseWithUploadedArtifact(entryId: entry.id, artifactId: artifact.id)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let executor = TaskExecutor(
            apiClient: APIClient(session: URLSession(configuration: configuration)),
            store: QueueStore(modelContext: modelContext),
            session: URLSession(configuration: .ephemeral)
        )
        let item = SyncQueueItem(
            id: "artifact-retry",
            type: SyncTaskType.syncArtifact.rawValue,
            payloadJSON: "{\"artifactId\":\"\(artifact.id)\"}"
        )

        try await executor.execute(item: item, accessToken: "access-token")

        XCTAssertEqual(artifact.uploadState, .uploaded)
        XCTAssertEqual(artifact.syncPhase, .uploaded)
        XCTAssertEqual(artifact.storageKey, "artifacts/\(entry.id)/\(artifact.id)")
        XCTAssertEqual(artifact.remoteUrl, "https://storage.example.test/\(artifact.id)")
    }

    private func makeArtifactRetryFixture(localFileURL: URL) -> (LocalPracticeEntry, LocalArtifact) {
        let entry = LocalPracticeEntry(
            id: "entry-artifact-retry",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(practiceDate: Date(), goalText: "Goal", durationSeconds: nil, tags: [], notes: nil),
            status: .draft
        )
        let artifact = LocalArtifact(
            id: "artifact-already-uploaded",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 30,
            localPath: localFileURL.path
        )
        entry.artifacts.append(artifact)
        return (entry, artifact)
    }
}

final class CameraPrivacyConfigurationTests: XCTestCase {
    func testInfoPlistDeclaresCameraUsageDescription() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let infoPlistURL = packageRoot.appendingPathComponent("Sources/Resources/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        let cameraPurpose = try XCTUnwrap(plist["NSCameraUsageDescription"] as? String)
        XCTAssertFalse(cameraPurpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

final class EntryDeletionCoordinatorTests: XCTestCase {
    @MainActor
    func testDeletingEntryCancelsQueuedWorkAndPersistsOneRemoteDelete() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeEntry(id: "entry-unsynced")
        let artifactURL = FileManager.default.temporaryDirectory.appendingPathComponent("entry-unsynced-audio.m4a")
        try Data("audio".utf8).write(to: artifactURL)

        let artifact = LocalArtifact(
            id: "artifact-unsynced",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 12,
            localPath: artifactURL.path
        )
        entry.artifacts.append(artifact)
        modelContext.insert(entry)
        modelContext.insert(artifact)
        modelContext.insert(makeQueueItem(id: "create-entry", type: .createEntry, payload: ["entryId": entry.id], status: .failed))
        modelContext.insert(makeQueueItem(id: "sync-artifact", type: .syncArtifact, payload: ["artifactId": artifact.id], status: .processing))
        modelContext.insert(makeQueueItem(id: "post-feedback", type: .postFeedback, payload: ["targetId": artifact.id, "targetType": "artifact"], status: .pending))
        try modelContext.save()

        let result = try EntryDeletionCoordinator.delete(entry: entry, modelContext: modelContext)

        XCTAssertTrue(result.enqueuedRemoteDelete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalArtifact>()).isEmpty)
        let remainingQueueItems = try modelContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(remainingQueueItems.count, 1)
        XCTAssertEqual(remainingQueueItems.first?.type, SyncTaskType.deleteEntry.rawValue)
        XCTAssertTrue(remainingQueueItems.first?.payloadJSON.contains(entry.id) == true)
    }

    @MainActor
    func testDeletingSyncedEntryKeepsOnlyRemoteDeleteQueueItem() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeEntry(id: "entry-synced")
        let artifactURL = FileManager.default.temporaryDirectory.appendingPathComponent("entry-synced-audio.m4a")
        try Data("audio".utf8).write(to: artifactURL)

        let artifact = LocalArtifact(
            id: "artifact-synced",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 8,
            localPath: artifactURL.path
        )
        entry.artifacts.append(artifact)
        modelContext.insert(entry)
        modelContext.insert(artifact)
        modelContext.insert(makeQueueItem(id: "sync-artifact", type: .syncArtifact, payload: ["artifactId": artifact.id], status: .failed))
        try modelContext.save()

        let result = try EntryDeletionCoordinator.delete(entry: entry, modelContext: modelContext)

        XCTAssertTrue(result.enqueuedRemoteDelete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalArtifact>()).isEmpty)

        let remainingQueueItems = try modelContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(remainingQueueItems.count, 1)
        XCTAssertEqual(remainingQueueItems.first?.type, SyncTaskType.deleteEntry.rawValue)
    }

    @MainActor
    func testMediaDeletionFailureLeavesLocalRecordsAndQueueWorkIntact() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeEntry(id: "entry-media-failure")
        let artifact = LocalArtifact(
            id: "artifact-media-failure",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 8,
            localPath: "/unavailable/media.m4a"
        )
        entry.artifacts.append(artifact)
        modelContext.insert(entry)
        modelContext.insert(artifact)
        modelContext.insert(makeQueueItem(id: "create-entry", type: .createEntry, payload: ["entryId": entry.id], status: .pending))
        try modelContext.save()

        XCTAssertThrowsError(
            try EntryDeletionCoordinator.delete(
                entry: entry,
                modelContext: modelContext,
                removeArtifactFile: { _ in throw EntryDeletionTestError.mediaDeletionFailed }
            )
        )

        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).count, 1)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<LocalArtifact>()).count, 1)
        let queueItems = try modelContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(queueItems.count, 1)
        XCTAssertEqual(queueItems.first?.type, SyncTaskType.createEntry.rawValue)
    }

    @MainActor
    func testAdditionalOwnedMediaPathIsDeletedOnceWithEntry() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeEntry(id: "entry-extra-media")
        let extraURL = FileManager.default.temporaryDirectory.appendingPathComponent("entry-extra-media.m4a")
        try Data("recording".utf8).write(to: extraURL)
        defer { try? FileManager.default.removeItem(at: extraURL) }
        modelContext.insert(entry)
        try modelContext.save()
        var removedPaths: [String] = []

        _ = try EntryDeletionCoordinator.delete(
            entry: entry,
            modelContext: modelContext,
            additionalOwnedMediaPaths: [extraURL.path, extraURL.path],
            removeArtifactFile: { path in
                removedPaths.append(path)
                try FileStore.removeFileIfExists(atPath: path)
            }
        )

        XCTAssertEqual(removedPaths, [extraURL.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraURL.path))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
    }

    @MainActor
    func testAdditionalOwnedMediaFailurePreservesPathForSuccessfulRetry() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeEntry(id: "entry-extra-media-failure")
        modelContext.insert(entry)
        modelContext.insert(makeQueueItem(id: "create-entry", type: .createEntry, payload: ["entryId": entry.id], status: .pending))
        try modelContext.save()

        XCTAssertThrowsError(
            try EntryDeletionCoordinator.delete(
                entry: entry,
                modelContext: modelContext,
                additionalOwnedMediaPaths: ["/unavailable/recorder.m4a"],
                removeArtifactFile: { _ in throw EntryDeletionTestError.mediaDeletionFailed }
            )
        )

        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).count, 1)
        let queueItems = try modelContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(queueItems.count, 1)
        XCTAssertEqual(queueItems.first?.type, SyncTaskType.createEntry.rawValue)

        var retriedPaths: [String] = []
        _ = try EntryDeletionCoordinator.delete(
            entry: entry,
            modelContext: modelContext,
            additionalOwnedMediaPaths: ["/unavailable/recorder.m4a"],
            removeArtifactFile: { retriedPaths.append($0) }
        )

        XCTAssertEqual(retriedPaths, ["/unavailable/recorder.m4a"])
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
        XCTAssertEqual(
            try modelContext.fetch(FetchDescriptor<SyncQueueItem>()).map(\.type),
            [SyncTaskType.deleteEntry.rawValue]
        )
    }

    @MainActor
    private func makeEntry(id: String) -> LocalPracticeEntry {
        LocalPracticeEntry(
            id: id,
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(practiceDate: Date(), goalText: "Goal", durationSeconds: nil, tags: [], notes: nil),
            status: .draft
        )
    }

    private func makeQueueItem(
        id: String,
        type: SyncTaskType,
        payload: [String: Any],
        status: SyncStatus
    ) -> SyncQueueItem {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            preconditionFailure("The supplied queue payload must be JSON-serializable")
        }
        guard let payloadJSON = String(bytes: data, encoding: .utf8) else {
            preconditionFailure("A JSON queue payload must be valid UTF-8")
        }
        let item = SyncQueueItem(id: id, type: type.rawValue, payloadJSON: payloadJSON)
        item.status = status.rawValue
        return item
    }
}

private enum EntryDeletionTestError: Error {
    case mediaDeletionFailed
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("MockURLProtocol.requestHandler not set")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class EntryReconciliationURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("EntryReconciliationURLProtocol.requestHandler not set")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ArtifactPlaybackURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("ArtifactPlaybackURLProtocol.requestHandler not set")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func submitEntryResponseJSON(id: String, status: String) -> Data {
    """
    {
        "id": "\(id)",
        "courseId": "course-1",
        "studentId": "student-1",
        "kind": "practice",
        "practiceDate": "2026-02-23T12:00:00Z",
        "goalText": "Submitted only after server success",
        "durationSeconds": null,
        "tags": ["tone"],
        "notes": null,
        "status": "\(status)",
        "consentConfirmedAt": null,
        "consentScope": null,
        "captureProfile": null,
        "captureMarkers": []
    }
    """.data(using: .utf8)!
}

private func entryResponseWithUploadedArtifact(entryId: String, artifactId: String) -> Data {
    """
    {
      "id": "\(entryId)",
      "courseId": "course-1",
      "studentId": "student-1",
      "kind": "practice",
      "practiceDate": "2026-02-23T12:00:00Z",
      "goalText": "Goal",
      "durationSeconds": null,
      "tags": [],
      "notes": null,
      "status": "draft",
      "consentConfirmedAt": null,
      "consentScope": null,
      "captureProfile": null,
      "captureMarkers": [],
      "artifacts": [
        {
          "id": "\(artifactId)",
          "entryId": "\(entryId)",
          "type": "audio",
          "durationSeconds": 30,
          "expectedSizeBytes": 5,
          "uploadState": "uploaded",
          "storageKey": "artifacts/\(entryId)/\(artifactId)",
          "remoteUrl": "https://storage.example.test/\(artifactId)"
        }
      ]
    }
    """.data(using: .utf8)!
}

private func makeUnexpiredJWT() -> String {
    let header = base64URLString(from: Data("{\"alg\":\"none\"}".utf8))
    let payload = base64URLString(from: Data("{\"exp\":\(Int(Date().addingTimeInterval(3600).timeIntervalSince1970))}".utf8))
    return "\(header).\(payload).signature"
}

private func base64URLString(from data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
