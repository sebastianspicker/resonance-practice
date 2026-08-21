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
    syncManager.enqueue(type: .updateEntry, payload: ["entryId": entry.id])
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

    syncManager.enqueue(type: .createEntry, payload: ["value": Double.nan])

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
      AppConfig.resolveAPIBaseURL("https://api.example.edu/tenant").absoluteString,
      "https://api.example.edu/tenant")
    for invalid in ["api.example.edu", "https://user:secret@api.example.edu", "ftp://api.example.edu"] {
      XCTAssertEqual(AppConfig.resolveAPIBaseURL(invalid).absoluteString, "http://localhost:4000")
    }
  }

  func testVersionedAPIPathsRemainAbsoluteAcrossBaseURLPaths() {
    XCTAssertEqual(AppConfig.apiV1URL(path: "/sync/commands/").path, "/api/v1/sync/commands")
  }
}
