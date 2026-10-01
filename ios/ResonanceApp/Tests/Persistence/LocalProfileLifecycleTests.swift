import Foundation
import SwiftData
import XCTest

@testable import ResonanceApp

final class LocalProfileLifecycleTests: XCTestCase {
  @MainActor
  func testFirstActivationBindsOwner() throws {
    let harness = LocalProfileHarness()

    XCTAssertTrue(try harness.lifecycle.activate(userId: "student-1"))

    XCTAssertEqual(harness.owner, "student-1")
    XCTAssertEqual(harness.events, ["setOwner:student-1"])
  }

  @MainActor
  func testFirstActivationRefusesUnownedLegacyData() throws {
    let harness = LocalProfileHarness()
    harness.context.insert(LocalCourse(id: "course-1", title: "Course", roleInCourse: "student"))
    try harness.context.save()

    XCTAssertFalse(try harness.lifecycle.activate(userId: "student-1"))

    XCTAssertNil(harness.owner)
    XCTAssertTrue(harness.events.isEmpty)
  }

  @MainActor
  func testFirstActivationRefusesUnownedStoredMedia() throws {
    let harness = LocalProfileHarness()
    harness.mediaPresent = true

    XCTAssertFalse(try harness.lifecycle.activate(userId: "student-1"))

    XCTAssertNil(harness.owner)
  }

  @MainActor
  func testSameOwnerReactivatesWithoutPurging() throws {
    let harness = LocalProfileHarness(owner: "student-1")
    try harness.seedAllModels()

    XCTAssertTrue(try harness.lifecycle.activate(userId: "student-1"))

    XCTAssertEqual(harness.owner, "student-1")
    XCTAssertEqual(harness.events, ["setOwner:student-1"])
    XCTAssertTrue(try harness.containsAnyModel())
  }

  @MainActor
  func testDifferentOwnerIsRefusedAndInvalidatesProcessing() throws {
    let harness = LocalProfileHarness(owner: "student-1")
    try harness.seedAllModels()

    XCTAssertFalse(try harness.lifecycle.activate(userId: "student-2"))

    XCTAssertEqual(harness.owner, "student-1")
    XCTAssertEqual(harness.events, ["invalidate"])
    XCTAssertTrue(try harness.containsAnyModel())
  }

  @MainActor
  func testActivationThrowsWhenOwnerCannotBeVerified() {
    let harness = LocalProfileHarness()
    harness.ownerWritesPersist = false

    XCTAssertThrowsError(try harness.lifecycle.activate(userId: "student-1")) { error in
      guard case LocalProfileLifecycleError.localDataOwnerVerificationFailed = error else {
        return XCTFail("Expected owner verification failure, got \(error)")
      }
    }
  }

  @MainActor
  func testReplacePurgesAllModelsAndRebinds() async throws {
    let harness = LocalProfileHarness(owner: "student-1")
    try harness.seedAllModels()
    harness.mediaPresent = true

    try await harness.lifecycle.replace(with: "student-2")

    XCTAssertEqual(harness.owner, "student-2")
    XCTAssertFalse(harness.mediaPresent)
    XCTAssertFalse(try harness.containsAnyModel())
    XCTAssertEqual(
      harness.events,
      ["cancel", "removeMedia", "save", "removeCalendarSubscription", "setOwner:student-2"])
  }

  @MainActor
  func testReplaceFailsClosedWhenPurgeCannotBeVerified() async throws {
    let harness = LocalProfileHarness(owner: "student-1")
    harness.mediaRemovalPersists = false
    harness.mediaPresent = true

    await assertThrowsAsync(try await harness.lifecycle.replace(with: "student-2")) { error in
      guard case LocalProfileLifecycleError.localDataStillExists = error else {
        return XCTFail("Expected local data verification failure, got \(error)")
      }
    }

    XCTAssertEqual(harness.owner, "student-1")
    XCTAssertEqual(harness.events, ["cancel", "removeMedia", "save"])
  }

  @MainActor
  func testSignOutDeletesLocalDataAndCredentialsThenRevokes() async throws {
    let harness = LocalProfileHarness(owner: "student-1")
    try harness.seedAllModels()
    harness.mediaPresent = true

    try await harness.lifecycle.signOutAndDeleteLocalData()

    XCTAssertNil(harness.owner)
    XCTAssertFalse(harness.mediaPresent)
    XCTAssertFalse(try harness.containsAnyModel())
    XCTAssertEqual(
      harness.events,
      [
        "cancel", "clearCredentials", "removeMedia", "save", "removeCalendarSubscription",
        "removeOwner", "revoke:student-1"
      ])
  }

  @MainActor
  func testSignOutStillRevokesAndKeepsOwnerWhenPurgeFails() async throws {
    let harness = LocalProfileHarness(owner: "student-1")
    try harness.seedAllModels()
    harness.mediaRemovalError = URLError(.cannotRemoveFile)

    await assertThrowsAsync(try await harness.lifecycle.signOutAndDeleteLocalData()) { error in
      XCTAssertEqual((error as? URLError)?.code, .cannotRemoveFile)
    }

    XCTAssertEqual(harness.owner, "student-1")
    XCTAssertTrue(try harness.containsAnyModel())
    XCTAssertEqual(harness.events, ["cancel", "clearCredentials", "removeMedia", "revoke:student-1"])
  }

  @MainActor
  func testSignOutDoesNotPurgeOrRevokeWhenCredentialsCannotBeCleared() async throws {
    let harness = LocalProfileHarness(owner: "student-1")
    try harness.seedAllModels()
    harness.clearCredentialsError = URLError(.userAuthenticationRequired)

    await assertThrowsAsync(try await harness.lifecycle.signOutAndDeleteLocalData()) { error in
      XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired)
    }

    XCTAssertEqual(harness.owner, "student-1")
    XCTAssertTrue(try harness.containsAnyModel())
    XCTAssertEqual(harness.events, ["cancel", "clearCredentials"])
  }

  @MainActor
  private func assertThrowsAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void
  ) async {
    do {
      try await expression()
      XCTFail("Expected an error", file: file, line: line)
    } catch {
      handler(error)
    }
  }
}

/// Records every lifecycle effect against an in-memory store so ordering is observable.
@MainActor
private final class LocalProfileHarness {
  let container = PersistenceController.createContainer(inMemory: true)
  var context: ModelContext { container.mainContext }
  var owner: String?
  var ownerWritesPersist = true
  var mediaPresent = false
  var mediaRemovalPersists = true
  var mediaRemovalError: Error?
  var clearCredentialsError: Error?
  private(set) var events: [String] = []

  init(owner: String? = nil) {
    self.owner = owner
  }

  var lifecycle: LocalProfileLifecycle {
    let context = context
    return LocalProfileLifecycle(dependencies: .init(
      modelContext: context,
      fetchArtifacts: { try context.fetch(FetchDescriptor<LocalArtifact>()) },
      saveChanges: {
        self.events.append("save")
        try context.save()
      },
      removeStoredMediaFiles: {
        self.events.append("removeMedia")
        if let error = self.mediaRemovalError { throw error }
        if self.mediaRemovalPersists { self.mediaPresent = false }
      },
      hasStoredMediaFiles: { self.mediaPresent },
      removeCalendarSubscription: { self.events.append("removeCalendarSubscription") },
      localDataOwner: { self.owner },
      setLocalDataOwner: { userId in
        self.events.append("setOwner:\(userId)")
        if self.ownerWritesPersist { self.owner = userId }
      },
      removeLocalDataOwner: {
        self.events.append("removeOwner")
        self.owner = nil
      },
      clearLocalCredentials: {
        self.events.append("clearCredentials")
        if let error = self.clearCredentialsError { throw error }
        return AuthSession(
          accessToken: "access", refreshToken: "refresh", userId: self.owner ?? "",
          displayName: "Student", globalRole: "student")
      },
      revokeRemoteSession: { session in self.events.append("revoke:\(session?.userId ?? "none")") },
      invalidateProcessing: { self.events.append("invalidate") },
      cancelAndWaitForProcessing: { self.events.append("cancel") }
    ))
  }

  func seedAllModels() throws {
    let entry = makeDraftPracticeEntry(id: "entry-1", goalText: "Goal", tags: [])
    let artifact = LocalArtifact(
      id: "artifact-1", entryId: entry.id, type: .audio, durationSeconds: 30, localPath: "")
    let feedback = LocalFeedback(
      id: "feedback-1", targetType: "entry", targetId: entry.id, teacherName: "Teacher",
      status: .accepted, commentsText: "Comments")
    let marker = LocalMarker(id: "marker-1", timeSeconds: 5, text: "Marker")
    feedback.markers.append(marker)
    entry.artifacts.append(artifact)
    context.insert(LocalCourse(id: "course-1", title: "Course", roleInCourse: "student"))
    context.insert(entry)
    context.insert(artifact)
    context.insert(feedback)
    context.insert(marker)
    context.insert(LocalCaptureMarker(
      id: "capture-1", entryId: entry.id, artifactId: artifact.id, timeSeconds: 1, kind: .phaseSetup))
    context.insert(SyncQueueItem(id: "queue-1", type: "updateEntry", payloadJSON: "{}", ownerId: "student-1"))
    context.insert(CalendarEvent(
      id: "event-1", summary: "Lesson", startDate: Date(), endDate: Date(), location: nil))
    try context.save()
  }

  func containsAnyModel() throws -> Bool {
    try context.containsModels(of: PersistenceController.modelTypes)
  }
}
