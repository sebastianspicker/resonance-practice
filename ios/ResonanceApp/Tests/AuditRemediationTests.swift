import XCTest
import Foundation
import SwiftData
@testable import ResonanceApp

final class SyncQueueCoalescingTests: XCTestCase {
    @MainActor
    func testProcessQueueCoalescesConcurrentTriggersAndProcessesNewItemsOnce() async throws {
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

final class EntryDeletionCoordinatorTests: XCTestCase {
    @MainActor
    func testDeletingUnsyncedEntryRemovesLocalDataFilesAndQueueItemsWithoutRemoteDelete() throws {
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

        var enqueuedPayloads: [[String: Any]] = []
        let result = try EntryDeletionCoordinator.delete(entry: entry, modelContext: modelContext) { _, payload in
            enqueuedPayloads.append(payload)
        }

        XCTAssertFalse(result.enqueuedRemoteDelete)
        XCTAssertTrue(enqueuedPayloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalArtifact>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<SyncQueueItem>()).isEmpty)
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
        modelContext.insert(makeQueueItem(id: "upload-artifact", type: .uploadArtifact, payload: ["artifactId": artifact.id], status: .failed))
        try modelContext.save()

        let result = try EntryDeletionCoordinator.delete(entry: entry, modelContext: modelContext) { type, payload in
            modelContext.insert(self.makeQueueItem(id: "delete-entry", type: type, payload: payload, status: .pending))
        }

        XCTAssertTrue(result.enqueuedRemoteDelete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalArtifact>()).isEmpty)

        let remainingQueueItems = try modelContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(remainingQueueItems.count, 1)
        XCTAssertEqual(remainingQueueItems.first?.type, SyncTaskType.deleteEntry.rawValue)
    }

    @MainActor
    private func makeEntry(id: String) -> LocalPracticeEntry {
        LocalPracticeEntry(
            id: id,
            courseId: "course-1",
            studentId: "student-1",
            practiceDate: Date(),
            goalText: "Goal",
            durationSeconds: nil,
            tags: [],
            notes: nil,
            status: .draft
        )
    }

    private func makeQueueItem(
        id: String,
        type: SyncTaskType,
        payload: [String: Any],
        status: SyncStatus
    ) -> SyncQueueItem {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let item = SyncQueueItem(id: id, type: type.rawValue, payloadJSON: String(decoding: data, as: UTF8.self))
        item.status = status.rawValue
        return item
    }
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
