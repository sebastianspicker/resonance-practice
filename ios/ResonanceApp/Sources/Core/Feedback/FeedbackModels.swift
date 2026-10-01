import Foundation
import SwiftData

@Model
final class LocalFeedback {
    @Attribute(.unique) var id: String
    var targetType: String; var targetId: String; var teacherName: String
    var statusRaw: String; var commentsText: String; var createdAt: Date
    @Relationship var parentEntry: LocalPracticeEntry?
    @Relationship(deleteRule: .cascade, inverse: \LocalMarker.feedback) var markers: [LocalMarker]
    init(id: String, targetType: String, targetId: String, teacherName: String, status: FeedbackStatus, commentsText: String) {
        self.id = id; self.targetType = targetType; self.targetId = targetId; self.teacherName = teacherName
        self.statusRaw = status.rawValue; self.commentsText = commentsText; self.createdAt = Date(); self.markers = []
    }
    var status: FeedbackStatus { get { FeedbackStatus(rawValue: statusRaw) ?? .accepted } set { statusRaw = newValue.rawValue } }
}

extension LocalFeedback {
    /// SwiftData relationships do not preserve insertion order, so feedback markers
    /// cross transport boundaries in a stable chronological order.
    var chronologicallyOrderedMarkers: [LocalMarker] {
        markers.sorted {
            ($0.timeSeconds, $0.id) < ($1.timeSeconds, $1.id)
        }
    }
}

@Model
final class LocalMarker {
    @Attribute(.unique) var id: String; var timeSeconds: Int; var text: String
    @Relationship var feedback: LocalFeedback?
    init(id: String, timeSeconds: Int, text: String) { self.id = id; self.timeSeconds = timeSeconds; self.text = text }
}

@Model
final class LocalCaptureMarker {
    @Attribute(.unique) var id: String; var entryId: String; var artifactId: String; var timeSeconds: Int
    var kindRaw: String; var note: String?; var createdAt: Date
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
        self.id = id; self.entryId = entryId; self.artifactId = artifactId; self.timeSeconds = timeSeconds
        self.kindRaw = kind.rawValue; self.note = note; self.createdAt = createdAt
    }
    var kind: CaptureMarkerKind {
        get { CaptureMarkerKind(rawValue: kindRaw) ?? .phaseSetup }
        set { kindRaw = newValue.rawValue }
    }
}
