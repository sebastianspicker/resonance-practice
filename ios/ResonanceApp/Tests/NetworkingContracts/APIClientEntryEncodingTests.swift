import Foundation
import XCTest

@testable import ResonanceApp

final class APIClientRequestEncodingTests: APIRequestCaptureTestCase {
  @MainActor
  func testTeachingLessonCommandEncodesConsentMetadata() async throws {
    let expectedURL = ServiceConfiguration.apiV1URL(path: "sync/commands")
    let capture = installRequestBodyCapture(
      expectedURL: expectedURL,
      method: "POST",
      response: Data(
        """
        {"results":[{"operationId":"entry-teaching","entityId":"entry-teaching","kind":"createEntry","status":"applied","currentVersion":1}]}
        """.utf8)
    )

    _ = try await makeCapturingAPIClient().sendSyncCommands(
      accessToken: "access-token",
      commands: [
        SyncCommand(
          operationId: "entry-teaching",
          entityId: "entry-teaching",
          kind: .createEntry,
          payload: .object([
            "courseId": .string("course-1"),
            "kind": .string("teaching_lesson"),
            "consentConfirmedAt": .string("2026-02-23T12:01:00.000Z"),
            "consentScope": .string("private_course_review"),
            "captureProfile": .string("teacher_learner"),
          ])
        )
      ]
    )

    let json = try decodedJSON(from: capture)
    let command = try XCTUnwrap((json["commands"] as? [[String: Any]])?.first)
    let payload = try XCTUnwrap(command["payload"] as? [String: Any])
    XCTAssertEqual(command["kind"] as? String, "createEntry")
    XCTAssertEqual(payload["kind"] as? String, "teaching_lesson")
    XCTAssertEqual(payload["consentConfirmedAt"] as? String, "2026-02-23T12:01:00.000Z")
    XCTAssertEqual(payload["consentScope"] as? String, "private_course_review")
    XCTAssertEqual(payload["captureProfile"] as? String, "teacher_learner")
  }
}
