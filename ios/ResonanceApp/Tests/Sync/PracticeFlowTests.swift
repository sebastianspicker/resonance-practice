import SwiftData
import XCTest

@testable import ResonanceApp

final class PracticeFlowTests: XCTestCase {
  func testOfflineAndSendingStayUnconfirmedUntilAuthoritativeSubmission() {
    XCTAssertEqual(
      PracticeDeliveryState.resolve(status: .draft, hasSubmission: true, hasFailure: false, isOnline: false),
      .queued)
    XCTAssertEqual(
      PracticeDeliveryState.resolve(status: .draft, hasSubmission: true, hasFailure: false, isOnline: true),
      .sending)
    XCTAssertEqual(
      PracticeDeliveryState.resolve(status: .draft, hasSubmission: false, hasFailure: false, isOnline: true),
      .unqueued)
    XCTAssertEqual(
      PracticeDeliveryState.resolve(status: .submitted, hasSubmission: false, hasFailure: false, isOnline: false),
      .submitted)
  }

  func testFailureCannotShowSubmissionSuccessAndReviewRemainsDistinct() {
    XCTAssertEqual(
      PracticeDeliveryState.resolve(status: .draft, hasSubmission: true, hasFailure: true, isOnline: true),
      .failed)
    XCTAssertEqual(
      PracticeDeliveryState.resolve(status: .reviewed, hasSubmission: false, hasFailure: false, isOnline: true),
      .reviewed)
    XCTAssertFalse(PracticeDeliveryState.queued.isConfirmed)
    XCTAssertFalse(PracticeDeliveryState.failed.isConfirmed)
  }

  @MainActor
  func testSubmissionLookupIsBoundToBothEntryAndOwnerAndRejectsMalformedWork() throws {
    let payload = try OutboxEnvelope(taskType: .submitEntry, payload: .entry(.init(entryId: "entry-a"))).encodedJSON()
    let item = SyncQueueItem(id: "operation-a", type: "submitEntry", payloadJSON: payload, ownerId: "student-a")
    XCTAssertTrue(PracticeDeliveryState.belongsToEntry(item, entryID: "entry-a", ownerID: "student-a"))
    XCTAssertFalse(PracticeDeliveryState.belongsToEntry(item, entryID: "entry-b", ownerID: "student-a"))
    XCTAssertFalse(PracticeDeliveryState.belongsToEntry(item, entryID: "entry-a", ownerID: "student-b"))
    item.payloadJSON = "invalid"
    XCTAssertFalse(PracticeDeliveryState.belongsToEntry(item, entryID: "entry-a", ownerID: "student-a"))
  }

  @MainActor
  func testDraftStartsAtRecordingOrReflectionAndReviewedEntryOpensReceipt() {
    let entry = LocalPracticeEntry(
      id: "entry-a", courseId: "course-a", studentId: "student-a",
      details: PracticeEntryDetails(practiceDate: Date(), goalText: "An even pulse", durationSeconds: 1200, tags: [], notes: nil),
      status: .draft)
    XCTAssertEqual(PracticeEntryStage.initial(for: entry, section: nil), .record)
    entry.artifacts.append(LocalArtifact(id: "audio-a", entryId: entry.id, type: .audio, durationSeconds: 102, localPath: ""))
    XCTAssertEqual(PracticeEntryStage.initial(for: entry, section: nil), .reflect)
    XCTAssertEqual(PracticeEntryStage.initial(for: entry, section: "guided-check"), .check)
    entry.status = .reviewed
    XCTAssertEqual(PracticeEntryStage.initial(for: entry, section: nil), .receipt)
    XCTAssertEqual(PracticeEntryStage.initial(for: entry, section: "feedback"), .details)
    XCTAssertEqual(entry.durationSeconds, 1200)
    XCTAssertEqual(entry.artifacts.first?.durationSeconds, 102)
  }
}
