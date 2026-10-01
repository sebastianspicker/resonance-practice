import Foundation

// Validates raw new-entry form fields and constructs the corresponding local draft.

enum NewEntryDraftField {
    case goal
    case duration
    case tags
    case notes
}

enum NewEntryDraftValidationError: Error {
    case missingGoal
    case invalidDuration
    case invalidTags
    case invalidNotes

    var field: NewEntryDraftField {
        switch self {
        case .missingGoal: return .goal
        case .invalidDuration: return .duration
        case .invalidTags: return .tags
        case .invalidNotes: return .notes
        }
    }

    var message: String {
        switch self {
        case .missingGoal: return "Add a practice goal before saving."
        case .invalidDuration: return "Duration must be between 0 and 480 minutes."
        case .invalidTags: return "Use no more than 30 tags, with 100 characters per tag."
        case .invalidNotes: return "Notes must contain no more than 10,000 characters."
        }
    }
}

struct NewEntryDraft {
    let courseId: String
    let goalText: String
    let practiceDate: Date
    let durationMinutes: String
    let tags: String
    let notes: String
    let entryKind: EntryKind
    let consentConfirmed: Bool
    let captureProfile: CaptureProfile

    var parsedTags: [String] {
        tags.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    func validate() throws {
        guard !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NewEntryDraftValidationError.missingGoal
        }
        guard durationMinutes.isEmpty ||
            (Int(durationMinutes).map { (0...480).contains($0) } ?? false)
        else {
            throw NewEntryDraftValidationError.invalidDuration
        }
        guard parsedTags.count <= 30, parsedTags.allSatisfy({ $0.count <= 100 }) else {
            throw NewEntryDraftValidationError.invalidTags
        }
        guard notes.count <= 10_000 else {
            throw NewEntryDraftValidationError.invalidNotes
        }
    }

    func makeEntry(studentId: String) -> LocalPracticeEntry {
        LocalPracticeEntry(
            id: UUID().uuidString,
            courseId: courseId,
            studentId: studentId,
            details: PracticeEntryDetails(
                practiceDate: practiceDate,
                goalText: goalText.trimmingCharacters(in: .whitespacesAndNewlines),
                durationSeconds: Int(durationMinutes).map { $0 * 60 },
                tags: parsedTags,
                notes: notes.isEmpty ? nil : notes
            ),
            status: .draft,
            captureContext: CaptureContext(
                kind: entryKind,
                consentConfirmedAt: entryKind == .teachingLesson && consentConfirmed ? Date() : nil,
                consentScope: entryKind == .teachingLesson && consentConfirmed ? .privateCourseReview : nil,
                captureProfile: entryKind == .teachingLesson ? captureProfile : nil
            )
        )
    }
}
