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
    case ok
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
    // legacy values like "warmup, technique" decode as ["warmup", "technique"]
    // instead of ["warmup", " technique"].
    return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

@Model
final class LocalArtifact {
    @Attribute(.unique) var id: String
    var entryId: String
    @Relationship var entry: LocalPracticeEntry?
    var typeRaw: String
    var durationSeconds: Int
    var createdAt: Date
    var uploadStateRaw: String
    var syncPhaseRaw: String
    var storageKey: String?
    var remoteUrl: String?
    var localPath: String

    init(id: String, entryId: String, type: ArtifactType, durationSeconds: Int, localPath: String) {
        self.id = id
        self.entryId = entryId
        self.typeRaw = type.rawValue
        self.durationSeconds = durationSeconds
        self.createdAt = Date()
        self.uploadStateRaw = UploadState.pending.rawValue
        self.syncPhaseRaw = ArtifactSyncPhase.queued.rawValue
        self.storageKey = nil
        self.remoteUrl = nil
        self.localPath = localPath
    }

    var type: ArtifactType {
        get { ArtifactType(rawValue: typeRaw) ?? .audio }
        set { typeRaw = newValue.rawValue }
    }

    var uploadState: UploadState {
        get { UploadState(rawValue: uploadStateRaw) ?? .pending }
        set { uploadStateRaw = newValue.rawValue }
    }

    var syncPhase: ArtifactSyncPhase {
        get { ArtifactSyncPhase(rawValue: syncPhaseRaw) ?? .queued }
        set { syncPhaseRaw = newValue.rawValue }
    }
}

@Model
final class LocalFeedback {
    @Attribute(.unique) var id: String
    var targetType: String
    var targetId: String
    var teacherName: String
    var statusRaw: String
    var commentsText: String
    var createdAt: Date
    @Relationship var parentEntry: LocalPracticeEntry?
    @Relationship(deleteRule: .cascade, inverse: \LocalMarker.feedback) var markers: [LocalMarker]

    init(id: String, targetType: String, targetId: String, teacherName: String, status: FeedbackStatus, commentsText: String) {
        self.id = id
        self.targetType = targetType
        self.targetId = targetId
        self.teacherName = teacherName
        self.statusRaw = status.rawValue
        self.commentsText = commentsText
        self.createdAt = Date()
        self.markers = []
    }

    var status: FeedbackStatus {
        get { FeedbackStatus(rawValue: statusRaw) ?? .ok }
        set { statusRaw = newValue.rawValue }
    }
}

@Model
final class LocalMarker {
    @Attribute(.unique) var id: String
    var timeSeconds: Int
    var text: String
    @Relationship var feedback: LocalFeedback?

    init(id: String, timeSeconds: Int, text: String) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.text = text
    }
}

@Model
final class LocalCaptureMarker {
    @Attribute(.unique) var id: String
    var entryId: String
    var artifactId: String
    var timeSeconds: Int
    var kindRaw: String
    var note: String?
    var createdAt: Date
    @Relationship var entry: LocalPracticeEntry?

    init(
        id: String,
        entryId: String,
        artifactId: String,
        timeSeconds: Int,
        kind: CaptureMarkerKind,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.entryId = entryId
        self.artifactId = artifactId
        self.timeSeconds = timeSeconds
        self.kindRaw = kind.rawValue
        self.note = note
        self.createdAt = createdAt
    }

    var kind: CaptureMarkerKind {
        get { CaptureMarkerKind(rawValue: kindRaw) ?? .phaseSetup }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class SyncQueueItem {
    @Attribute(.unique) var id: String
    var type: String
    var payloadJSON: String
    var status: String
    var retryCount: Int
    var lastError: String?
    var createdAt: Date
    var nextAttemptAt: Date?

    init(id: String, type: String, payloadJSON: String) {
        self.id = id
        self.type = type
        self.payloadJSON = payloadJSON
        self.status = "pending"
        self.retryCount = 0
        self.createdAt = Date()
        self.nextAttemptAt = nil
    }
}

@Model
final class CalendarEvent {
    @Attribute(.unique) var id: String
    var summary: String
    var startDate: Date
    var endDate: Date
    var location: String?

    init(id: String, summary: String, startDate: Date, endDate: Date, location: String?) {
        self.id = id
        self.summary = summary
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
    }
}
