import Foundation
import XCTest

@testable import ResonanceApp

final class APIClientRequestEncodingTests: APIRequestCaptureTestCase {
  @MainActor
  func testTeachingLessonEntryEncodesConsentMetadata() async throws {
    let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("courses/course-1/entries")
    let capture = installRequestBodyCapture(
      expectedURL: expectedURL, method: "POST", response: teachingEntryResponse())
    let entry = LocalPracticeEntry(
      id: "entry-teaching",
      courseId: "course-1",
      studentId: "student-1",
      details: PracticeEntryDetails(
        practiceDate: Date(timeIntervalSince1970: 1_771_848_000), goalText: "Teach rhythm ostinato",
        durationSeconds: nil, tags: ["lehramt"], notes: nil),
      status: .draft,
      captureContext: CaptureContext(
        kind: .teachingLesson, consentConfirmedAt: Date(timeIntervalSince1970: 1_771_848_060),
        consentScope: .privateCourseReview, captureProfile: .teacherLearner)
    )

    _ = try await makeCapturingAPIClient().createEntry(
      accessToken: "access-token", courseId: "course-1", entry: entry)

    let json = try decodedJSON(from: capture)
    XCTAssertEqual(json["kind"] as? String, "teaching_lesson")
    XCTAssertEqual(json["consentConfirmed"] as? Bool, true)
    XCTAssertEqual(json["consentScope"] as? String, "private_course_review")
    XCTAssertEqual(json["captureProfile"] as? String, "teacher_learner")
  }
}
