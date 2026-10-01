import Foundation
import SwiftData
import XCTest

@testable import ResonanceApp

final class SyncManagerTests: XCTestCase {
  @MainActor
  func testReloadServerCopyReplacesLocalConflictAndDiscardsQueuedWork() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestRequestURLProtocol.self]
    let client = APIClient(session: URLSession(configuration: configuration))
    let container = PersistenceController.createContainer(inMemory: true)
    let auth = AuthManager(apiClient: client, removeSessionData: {})
    auth.session = AuthSession(
      accessToken: "token", refreshToken: "refresh", userId: "student-1", displayName: "Student",
      globalRole: "student")
    let syncManager = SyncManager(
      modelContext: container.mainContext, authManager: auth, apiClient: client,
      verifiedOwner: { "student-1" })
    let entry = makeDraftPracticeEntry(id: "entry-reload", goalText: "Local goal", tags: ["local"])
    entry.serverVersion = 1
    container.mainContext.insert(entry)
    syncManager.enqueue(type: .updateEntry, payload: .entry(.init(entryId: entry.id)))
    syncManager.conflictedEntryIDs.insert(entry.id)
    try container.mainContext.save()

    TestRequestURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/v1/entries/entry-reload")
      let url = try XCTUnwrap(request.url)
      return (
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(
          """
          {
            "id":"entry-reload","courseId":"course-1","studentId":"student-1",
            "kind":"teaching_lesson","practiceDate":"2026-01-02T12:00:00Z",
            "goalText":"Server goal","durationSeconds":900,"tags":["server"],
            "notes":"Remote note","status":"submitted",
            "consentConfirmedAt":"2026-01-01T12:00:00Z",
            "consentScope":"private_course_review","captureProfile":"ensemble_group","version":7
          }
          """.utf8)
      )
    }
    defer { TestRequestURLProtocol.requestHandler = nil }

    try await syncManager.reloadServerCopy(of: entry)

    XCTAssertEqual(entry.goalText, "Server goal")
    XCTAssertEqual(entry.tags, ["server"])
    XCTAssertEqual(entry.status, .submitted)
    XCTAssertEqual(entry.kind, .teachingLesson)
    XCTAssertEqual(entry.captureProfile, .ensembleGroup)
    XCTAssertEqual(entry.serverVersion, 7)
    XCTAssertFalse(syncManager.conflictedEntryIDs.contains(entry.id))
    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>()).isEmpty)
  }

  @MainActor
  func testBackgroundExpirationResetsProcessingItems() throws {
    let (container, syncManager) = makeSUT()
    let item = SyncQueueItem(
      id: "processing", type: "syncArtifact", payloadJSON: "{}", ownerId: "student-1")
    item.status = SyncStatus.processing.rawValue
    item.nextAttemptAt = Date().addingTimeInterval(60)
    container.mainContext.insert(item)
    try container.mainContext.save()

    syncManager.invalidateProcessing()

    XCTAssertEqual(item.status, SyncStatus.pending.rawValue)
    XCTAssertNil(item.nextAttemptAt)
  }

  @MainActor
  func testInvalidEnqueueDoesNotMutateQueue() throws {
    let (container, syncManager) = makeSUT()

    syncManager.enqueue(type: .createEntry, payload: .artifact(.init(artifactId: "artifact-1", baseVersion: nil)))

    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>()).isEmpty)
  }

  func testRetryBackoffIsBounded() {
    let policy = RetryPolicy()
    XCTAssertEqual(policy.backoffDelay(retryCount: 0), 1)
    XCTAssertEqual(policy.backoffDelay(retryCount: 100), 300)
  }

  @MainActor
  private func makeSUT() -> (ModelContainer, SyncManager) {
    let container = PersistenceController.createContainer(inMemory: true)
    let auth = AuthManager(apiClient: APIClient())
    auth.session = AuthSession(
      accessToken: "access-token", refreshToken: "refresh-token", userId: "student-1",
      displayName: "Student", globalRole: "student")
    return (
      container,
      SyncManager(
        modelContext: container.mainContext, authManager: auth, apiClient: APIClient(),
        verifiedOwner: { "student-1" })
    )
  }
}

final class AppConfigurationTests: XCTestCase {
  func testOnlyCredentialFreeHTTPOriginsBecomeAPIBaseURLs() {
    XCTAssertEqual(
      ServiceConfiguration.resolveAPIBaseURL("https://api.example.edu/tenant").absoluteString,
      "https://api.example.edu/tenant")
    for invalid in ["api.example.edu", "https://user:secret@api.example.edu", "ftp://api.example.edu"] {
      XCTAssertEqual(ServiceConfiguration.resolveAPIBaseURL(invalid).absoluteString, "http://localhost:4000")
    }
  }

  func testVersionedAPIPathsRemainAbsoluteAcrossBaseURLPaths() {
    XCTAssertEqual(ServiceConfiguration.apiV1URL(path: "/sync/commands/").path, "/api/v1/sync/commands")
  }
}

final class OutboxPayloadTests: XCTestCase {
  func testLegacyEntryPayloadMigratesToVersionedEnvelope() throws {
    let migrated = try OutboxEnvelope.decode(
      payloadJSON: #"{"entryId":"entry-1"}"#,
      taskType: .updateEntry)

    XCTAssertTrue(migrated.migrated)
    XCTAssertEqual(migrated.envelope.payload, .entry(.init(entryId: "entry-1")))

    let persisted = try migrated.envelope.encodedJSON()
    XCTAssertFalse(try OutboxEnvelope.decode(payloadJSON: persisted, taskType: .updateEntry).migrated)
  }
}

final class LocalMediaContainmentTests: XCTestCase {
  func testRejectsPathsOutsideManagedMediaDirectory() {
    XCTAssertThrowsError(try FileStore.containedMediaURL(atPath: "/tmp/untrusted.m4a")) { error in
      guard case FileStoreError.pathOutsideMediaDirectory = error else {
        return XCTFail("Expected path containment error, got \(error)")
      }
    }
  }
}

final class SyncQueueWindowTests: XCTestCase {
  @MainActor
  func testLargeOutboxFetchesOnlyOwnerReadyFIFOWindowAndCountsInStore() throws {
    let (container, store, now) = try makeLargeOutbox()
    defer { withExtendedLifetime(container) {} }

    let ready = try store.fetchReady(now: now, ownerId: "student-1")

    XCTAssertEqual(ready.count, 50)
    XCTAssertEqual(ready.map(\.id), (0..<50).map { String(format: "ready-%04d", $0) })
    XCTAssertEqual(store.counts(ownerId: "student-1").pending, 1_000)
    XCTAssertEqual(store.counts(ownerId: "student-2").pending, 80)
  }

  @MainActor
  func testLargeOutboxReadyWindowPerformance() throws {
    let (container, store, now) = try makeLargeOutbox()
    defer { withExtendedLifetime(container) {} }

    measure(metrics: [XCTClockMetric()]) {
      do {
        let ready = try store.fetchReady(now: now, ownerId: "student-1")
        XCTAssertEqual(ready.count, 50)
        XCTAssertEqual(store.counts(ownerId: "student-1").pending, 1_000)
      } catch {
        XCTFail("Fetching the seeded outbox failed: \(error)")
      }
    }
  }

  @MainActor
  private func makeLargeOutbox() throws -> (ModelContainer, QueueStore, Date) {
    let container = PersistenceController.createContainer(inMemory: true)
    let store = QueueStore(modelContext: container.mainContext)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Future-due work comes first in FIFO order. The ready window must scan
    // past it instead of starving the next ready item.
    for index in 0..<60 {
      let item = SyncQueueItem(
        id: String(format: "future-%04d", index), type: SyncTaskType.updateEntry.rawValue,
        payloadJSON: "{}", ownerId: "student-1")
      item.createdAt = now.addingTimeInterval(TimeInterval(-1_000 + index))
      item.nextAttemptAt = now.addingTimeInterval(60)
      container.mainContext.insert(item)
    }
    for index in 0..<940 {
      let item = SyncQueueItem(
        id: String(format: "ready-%04d", index), type: SyncTaskType.updateEntry.rawValue, payloadJSON: "{}",
        ownerId: "student-1")
      item.createdAt = now.addingTimeInterval(TimeInterval(index))
      container.mainContext.insert(item)
    }
    for index in 0..<80 {
      container.mainContext.insert(
        SyncQueueItem(id: "other-owner-\(index)", type: SyncTaskType.updateEntry.rawValue,
                      payloadJSON: "{}", ownerId: "student-2"))
    }
    try container.mainContext.save()
    return (container, store, now)
  }
}

final class ReconciliationTraversalTests: XCTestCase {
  @MainActor
  func testFailedSecondPagePreservesStaleAndQueuedLocalEntries() async throws {
    let client = makeReconciliationClient()
    let container = PersistenceController.createContainer(inMemory: true)
    let stale = makeRemoteEntry(id: "stale")
    let queued = makeRemoteEntry(id: "queued")
    container.mainContext.insert(stale)
    container.mainContext.insert(queued)
    let queuedPayload = try OutboxEnvelope(
      taskType: .updateEntry, payload: .entry(.init(entryId: queued.id))).encodedJSON()
    container.mainContext.insert(
      SyncQueueItem(id: "queued-command", type: SyncTaskType.updateEntry.rawValue,
                    payloadJSON: queuedPayload, ownerId: "student-1"))
    try container.mainContext.save()

    installReconciliationHandler { _ in throw URLError(.cannotLoadFromNetwork) }
    defer { TestRequestURLProtocol.requestHandler = nil }

    let reconciler = EntryReconciliationService(
      modelContext: container.mainContext, apiClient: client, ownerId: "student-1")
    await XCTAssertThrowsErrorAsync(try await reconciler.refresh(courseId: "course-1", accessToken: "token"))

    XCTAssertNotNil(try container.mainContext.fetch(FetchDescriptor<LocalPracticeEntry>(predicate: #Predicate { $0.id == "remote-1" })).first)
    XCTAssertNotNil(try container.mainContext.fetch(FetchDescriptor<LocalPracticeEntry>(predicate: #Predicate { $0.id == "stale" })).first)
    XCTAssertNotNil(try container.mainContext.fetch(FetchDescriptor<LocalPracticeEntry>(predicate: #Predicate { $0.id == "queued" })).first)
  }

  @MainActor
  func testCancelledTraversalDoesNotPerformStaleCleanup() async throws {
    let client = makeReconciliationClient()
    let container = PersistenceController.createContainer(inMemory: true)
    container.mainContext.insert(makeRemoteEntry(id: "stale"))
    try container.mainContext.save()
    let secondPageStarted = expectation(description: "second page started")
    let releaseSecondPage = DispatchSemaphore(value: 0)

    installReconciliationHandler { url in
      secondPageStarted.fulfill()
      _ = releaseSecondPage.wait(timeout: .now() + 2)
      return emptyReconciliationPage(url)
    }
    defer { TestRequestURLProtocol.requestHandler = nil }

    let reconciler = EntryReconciliationService(
      modelContext: container.mainContext, apiClient: client, ownerId: "student-1")
    let task = Task { @MainActor in
      try await reconciler.refresh(courseId: "course-1", accessToken: "token")
    }
    await fulfillment(of: [secondPageStarted], timeout: 2)
    task.cancel()
    releaseSecondPage.signal()
    await XCTAssertThrowsErrorAsync(try await task.value)

    XCTAssertNotNil(try container.mainContext.fetch(FetchDescriptor<LocalPracticeEntry>(predicate: #Predicate { $0.id == "stale" })).first)
  }

  @MainActor
  func testStaleCleanupPreservesOnlyCurrentOwnersQueuedEntries() async throws {
    let client = makeReconciliationClient()
    let container = PersistenceController.createContainer(inMemory: true)
    let ownedPending = makeRemoteEntry(id: "owned-pending")
    let otherOwnersPending = makeRemoteEntry(id: "other-owner-pending")
    container.mainContext.insert(ownedPending)
    container.mainContext.insert(otherOwnersPending)
    let ownedPayload = try OutboxEnvelope(
      taskType: .updateEntry, payload: .entry(.init(entryId: ownedPending.id))).encodedJSON()
    let otherPayload = try OutboxEnvelope(
      taskType: .updateEntry, payload: .entry(.init(entryId: otherOwnersPending.id))).encodedJSON()
    container.mainContext.insert(SyncQueueItem(
      id: "owned-command", type: SyncTaskType.updateEntry.rawValue,
      payloadJSON: ownedPayload, ownerId: "student-1"))
    container.mainContext.insert(SyncQueueItem(
      id: "other-command", type: SyncTaskType.updateEntry.rawValue,
      payloadJSON: otherPayload, ownerId: "student-2"))
    try container.mainContext.save()

    installReconciliationHandler(afterFirstPage: emptyReconciliationPage)
    defer { TestRequestURLProtocol.requestHandler = nil }

    let reconciler = EntryReconciliationService(
      modelContext: container.mainContext, apiClient: client, ownerId: "student-1")
    try await reconciler.refresh(courseId: "course-1", accessToken: "token")

    XCTAssertNotNil(try container.mainContext.fetch(FetchDescriptor<LocalPracticeEntry>(
      predicate: #Predicate { $0.id == "owned-pending" })).first)
    XCTAssertNil(try container.mainContext.fetch(FetchDescriptor<LocalPracticeEntry>(
      predicate: #Predicate { $0.id == "other-owner-pending" })).first)
  }

  @MainActor
  private func makeReconciliationClient() -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestRequestURLProtocol.self]
    return APIClient(session: URLSession(configuration: configuration))
  }
}

final class MediaPreparationTests: XCTestCase {
  func testBackgroundPreparationReturnsStreamingChecksumAndMetadata() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let data = Data(repeating: 0xA5, count: MediaChecksum.chunkSize * 32)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let preparation = try await MediaChecksum.prepare(for: url)

    XCTAssertEqual(preparation.sizeBytes, data.count)
    XCTAssertEqual(preparation.checksumSha256, try MediaChecksum.sha256Base64(for: url))
  }

  @MainActor
  func testChecksumPreparationResponsivenessSmoke() async throws {
    let (url, _) = try makeChecksumFixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let preparation = Task { try await MediaChecksum.prepare(for: url) }
    let heartbeat = expectation(description: "main actor heartbeat")
    Task { @MainActor in heartbeat.fulfill() }

    await fulfillment(of: [heartbeat], timeout: 2)
    let result = try await preparation.value
    XCTAssertEqual(result.sizeBytes, MediaChecksum.chunkSize * 32)
  }

  func testChecksumPreparationPerformance() throws {
    let (url, _) = try makeChecksumFixture()
    defer { try? FileManager.default.removeItem(at: url) }

    measure(metrics: [XCTClockMetric()]) {
      let completed = expectation(description: "checksum preparation")
      Task { @MainActor in
        do {
          let preparation = try await MediaChecksum.prepare(for: url)
          XCTAssertEqual(preparation.sizeBytes, MediaChecksum.chunkSize * 32)
        } catch {
          XCTFail("Checksum preparation failed: \(error)")
        }
        completed.fulfill()
      }
      wait(for: [completed], timeout: 5)
    }
  }

  private func makeChecksumFixture() throws -> (URL, Data) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let data = Data(repeating: 0xA5, count: MediaChecksum.chunkSize * 32)
    try data.write(to: url)
    return (url, data)
  }
}

final class JournalSectionPlannerTests: XCTestCase {
  func testLargeJournalIndexKeepsEntriesGroupedAndNewestDayFirst() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let calendar = Calendar(identifier: .gregorian)
    let index = (0..<1_000).map { offset in
      JournalEntryIndex(
        id: "entry-\(offset)",
        day: calendar.startOfDay(for: start.addingTimeInterval(TimeInterval(offset % 20) * 86_400)))
    }

    let days = JournalSectionPlanner.makeDays(from: index)

    XCTAssertEqual(days.count, 20)
    XCTAssertEqual(days.flatMap(\.entryIDs).count, index.count)
    XCTAssertEqual(days, days.sorted { $0.date > $1.date })
  }
}

final class CalendarPolicyTests: XCTestCase {
  func testCalendarPolicyRequiresHTTPSExceptLocalDevelopmentHosts() {
    XCTAssertTrue(CalendarService.isAllowedCalendarURL(URL(string: "https://calendar.example.edu/feed?token=secret")!))
    XCTAssertTrue(CalendarService.isAllowedCalendarURL(URL(string: "http://localhost:4000/feed")!))
    XCTAssertTrue(CalendarService.isAllowedCalendarURL(URL(string: "http://127.0.0.2:4000/feed")!))
    XCTAssertFalse(CalendarService.isAllowedCalendarURL(URL(string: "http://calendar.example.edu/feed")!))
    XCTAssertFalse(CalendarService.isAllowedCalendarURL(URL(string: "file:///tmp/calendar.ics")!))
  }

  func testCalendarPolicyRejectsHTTPSPrivateAndLocalDestinations() {
    [
      "https://localhost/feed",
      "https://calendar.local/feed",
      "https://127.0.0.1/feed",
      "https://10.0.0.1/feed",
      "https://172.16.0.1/feed",
      "https://192.168.0.1/feed",
      "https://169.254.1.1/feed",
      "https://[::1]/feed",
      "https://[fc00::1]/feed",
      "https://[fe80::1]/feed",
      "https://[::ffff:127.0.0.1]/feed",
      "https://[::ffff:10.0.0.1]/feed",
      "https://[::ffff:169.254.1.1]/feed",
    ].forEach { value in
      XCTAssertFalse(CalendarService.isAllowedCalendarURL(URL(string: value)!))
    }
  }

  func testCalendarRedirectPolicyRejectsMappedIPv4Destinations() {
    [
      "https://[::ffff:127.0.0.1]/feed",
      "https://[::ffff:192.168.0.1]/feed",
    ].forEach { value in
      XCTAssertFalse(CalendarRedirectPolicy.allowsRedirect(to: URL(string: value)!))
    }
  }
}

private func makeDraftPracticeEntry(id: String, goalText: String, tags: [String]) -> LocalPracticeEntry {
  LocalPracticeEntry(
    id: id,
    courseId: "course-1",
    studentId: "student-1",
    details: PracticeEntryDetails(
      practiceDate: Date(timeIntervalSince1970: 1_700_000_000),
      goalText: goalText,
      durationSeconds: nil,
      tags: tags,
      notes: nil),
    status: .draft)
}

private func makeRemoteEntry(id: String) -> LocalPracticeEntry {
  let entry = makeDraftPracticeEntry(id: id, goalText: "Local \(id)", tags: [])
  entry.remoteUpdatedAt = Date(timeIntervalSince1970: 1_600_000_000)
  entry.serverVersion = 1
  return entry
}

private func httpResponse(_ url: URL) -> HTTPURLResponse {
  HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
}

private func reconciliationPage(ids: [String], nextCursor: String?) -> Data {
  let items = ids.map { id in
    """
    {"id":"\(id)","courseId":"course-1","studentId":"student-1","practiceDate":"2026-01-02T12:00:00Z","goalText":"Goal \(id)","durationSeconds":null,"tags":[],"notes":null,"status":"submitted","artifacts":[]}
    """
  }.joined(separator: ",")
  let cursor = nextCursor.map { "\"\($0)\"" } ?? "null"
  return Data("{\"items\":[\(items)],\"nextCursor\":\(cursor)}".utf8)
}

private func emptyReconciliationPage(_ url: URL) -> (HTTPURLResponse, Data) {
  (httpResponse(url), reconciliationPage(ids: [], nextCursor: nil))
}

private func reconciliationRequestDetails(_ request: URLRequest) throws -> (URL, String?) {
  let url = try XCTUnwrap(request.url)
  let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
    .queryItems?.first(where: { $0.name == "cursor" })?.value
  return (url, cursor)
}

private func firstReconciliationPage(
  url: URL,
  cursor: String?
) -> (HTTPURLResponse, Data)? {
  guard cursor == nil else { return nil }
  return (httpResponse(url), reconciliationPage(ids: ["remote-1"], nextCursor: "next"))
}

private func installReconciliationHandler(
  afterFirstPage: @escaping (URL) throws -> (HTTPURLResponse, Data)
) {
  TestRequestURLProtocol.requestHandler = { request in
    let (url, cursor) = try reconciliationRequestDetails(request)
    if let firstPage = firstReconciliationPage(url: url, cursor: cursor) { return firstPage }
    return try afterFirstPage(url)
  }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected an error", file: file, line: line)
  } catch {}
}
