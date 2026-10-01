import Foundation
import SwiftData

enum EntryStatus: String, Codable {
    case draft
    case submitted
    case reviewed
}

enum ArtifactType: String, Codable {
    case audio
    case video
}

enum EntryKind: String, Codable {
    case practice
    case teachingLesson = "teaching_lesson"
}

enum ConsentScope: String, Codable {
    case privateCourseReview = "private_course_review"
}

enum CaptureProfile: String, Codable, CaseIterable, Identifiable {
    case roomOverview = "room_overview"
    case teacherLearner = "teacher_learner"
    case instrumentCloseup = "instrument_closeup"
    case ensembleGroup = "ensemble_group"
    case groupWork = "group_work"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .roomOverview: return "Room Overview"
        case .teacherLearner: return "Teacher + Learners"
        case .instrumentCloseup: return "Instrument Close-up"
        case .ensembleGroup: return "Ensemble Group"
        case .groupWork: return "Group Work"
        }
    }
}

enum CaptureMarkerKind: String, Codable, CaseIterable, Identifiable {
    case phaseSetup = "phase_setup"
    case phaseModeling = "phase_modeling"
    case phaseGuidedPractice = "phase_guided_practice"
    case phaseStudentWork = "phase_student_work"
    case phaseFeedback = "phase_feedback"
    case phaseReflection = "phase_reflection"
    case momentQuestion = "moment_question"
    case momentMusicalModel = "moment_musical_model"
    case momentStudentResponse = "moment_student_response"
    case momentTransition = "moment_transition"
    case privacyNote = "privacy_note"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .phaseSetup: return "Setup"
        case .phaseModeling: return "Modeling"
        case .phaseGuidedPractice: return "Guided Practice"
        case .phaseStudentWork: return "Student Work"
        case .phaseFeedback: return "Feedback"
        case .phaseReflection: return "Reflection"
        case .momentQuestion: return "Question"
        case .momentMusicalModel: return "Musical Model"
        case .momentStudentResponse: return "Student Response"
        case .momentTransition: return "Transition"
        case .privacyNote: return "Privacy Note"
        }
    }
}

enum UploadState: String, Codable {
    case pending
    case uploading
    case uploaded
    case failed
}

enum ArtifactSyncPhase: String, Codable {
    case queued
    case uploading
    case confirming
    case uploaded
    case failed
}

enum FeedbackStatus: String, Codable {
    case accepted = "ok"
    case needsRevision = "needs_revision"
    case nextGoal = "next_goal"
}

struct PracticeEntryDetails {
    let practiceDate: Date
    let goalText: String
    let durationSeconds: Int?
    let tags: [String]
    let notes: String?
}

struct CaptureContext {
    let kind: EntryKind
    let consentConfirmedAt: Date?
    let consentScope: ConsentScope?
    let captureProfile: CaptureProfile?

    static let practice = CaptureContext(
        kind: .practice,
        consentConfirmedAt: nil,
        consentScope: nil,
        captureProfile: nil
    )
}

@Model
final class LocalCourse {
    @Attribute(.unique) var id: String
    var title: String
    var roleInCourse: String

    init(id: String, title: String, roleInCourse: String) {
        self.id = id
        self.title = title
        self.roleInCourse = roleInCourse
    }
}

@Model
final class LocalPracticeEntry {
    @Attribute(.unique) var id: String
    var courseId: String
    var studentId: String
    var kindRaw: String
    var practiceDate: Date
    var goalText: String
    var durationSeconds: Int?
    var tagsCSV: String
    var notes: String?
    var statusRaw: String
    var consentConfirmedAt: Date?
    var consentScopeRaw: String?
    var captureProfileRaw: String?
    var updatedAt: Date
    var remoteUpdatedAt: Date?
    /// Optimistic-concurrency version returned by the command API.
    var serverVersion: Int?
    var deletedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \LocalArtifact.entry) var artifacts: [LocalArtifact]
    @Relationship(deleteRule: .cascade, inverse: \LocalFeedback.parentEntry) var feedback: [LocalFeedback]
    @Relationship(deleteRule: .cascade, inverse: \LocalCaptureMarker.entry) var captureMarkers: [LocalCaptureMarker]

    init(
        id: String,
        courseId: String,
        studentId: String,
        details: PracticeEntryDetails,
        status: EntryStatus,
        captureContext: CaptureContext = .practice
    ) {
        self.id = id
        self.courseId = courseId
        self.studentId = studentId
        self.kindRaw = captureContext.kind.rawValue
        self.practiceDate = details.practiceDate
        self.goalText = details.goalText
        self.durationSeconds = details.durationSeconds
        self.tagsCSV = encodeTags(details.tags)
        self.notes = details.notes
        self.statusRaw = status.rawValue
        self.consentConfirmedAt = captureContext.consentConfirmedAt
        self.consentScopeRaw = captureContext.consentScope?.rawValue
        self.captureProfileRaw = captureContext.captureProfile?.rawValue
        self.updatedAt = Date()
        self.remoteUpdatedAt = nil
        self.serverVersion = nil
        self.deletedAt = nil
        self.artifacts = []
        self.feedback = []
        self.captureMarkers = []
    }

    var status: EntryStatus {
        get { EntryStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var kind: EntryKind {
        get { EntryKind(rawValue: kindRaw) ?? .practice }
        set { kindRaw = newValue.rawValue }
    }

    var consentScope: ConsentScope? {
        get {
            guard let consentScopeRaw else { return nil }
            return ConsentScope(rawValue: consentScopeRaw)
        }
        set { consentScopeRaw = newValue?.rawValue }
    }

    var captureProfile: CaptureProfile? {
        get {
            guard let captureProfileRaw else { return nil }
            return CaptureProfile(rawValue: captureProfileRaw)
        }
        set { captureProfileRaw = newValue?.rawValue }
    }

    var tags: [String] {
        get { decodeTags(tagsCSV) }
        set { tagsCSV = encodeTags(newValue) }
    }
}

private func encodeTags(_ tags: [String]) -> String {
    if let data = try? JSONEncoder().encode(tags),
       let json = String(data: data, encoding: .utf8) {
        return json
    }
    return tags.joined(separator: ",")
}

private func decodeTags(_ value: String) -> [String] {
    if let data = value.data(using: .utf8),
       let decoded = try? JSONDecoder().decode([String].self, from: data) {
        return decoded
    }
    // Backward-compatible CSV fallback: trim whitespace around each tag so that
    // Installed-alpha persisted-data migration boundary: predecessor tag values like "warmup, technique" decode as ["warmup", "technique"].
    // instead of ["warmup", " technique"].
    return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}
