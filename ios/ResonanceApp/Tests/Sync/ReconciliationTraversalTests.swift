import Foundation
import SwiftData
import XCTest

@testable import ResonanceApp

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
    {"id":"\(id)","courseId":"course-1","studentId":"student-1","practiceDate":"2026-01-02T12:00:00Z",\
    "goalText":"Goal \(id)","durationSeconds":null,"tags":[],"notes":null,"status":"submitted","artifacts":[]}
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
