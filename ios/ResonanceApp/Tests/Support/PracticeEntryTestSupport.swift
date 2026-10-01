import Foundation

@testable import ResonanceApp

func makeDraftPracticeEntry(id: String, goalText: String, tags: [String]) -> LocalPracticeEntry {
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
