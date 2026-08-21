import Foundation

// Defines server projections for entries, reviews, and capture markers.

/// Authoritative server entry projection used to reconcile local SwiftData state.
struct EntryResponse: Decodable {
    let id: String
    let courseId: String
    let studentId: String
    let kind: String?
    let practiceDate: Date
    let goalText: String
    let durationSeconds: Int?
    let tags: [String]
    let notes: String?
    let status: String
    let consentConfirmedAt: Date?
    let consentScope: String?
    let captureProfile: String?
    let captureMarkers: [CaptureMarkerResponse]?
    let artifacts: [ArtifactResponse]?
    let createdAt: Date?
    let updatedAt: Date?
    let version: Int?
}

struct ReviewQueueEntry: Decodable {
    let id: String
    let courseId: String
    let studentId: String
    let studentName: String
    let kind: String?
    let practiceDate: Date
    let goalText: String
    let notes: String?
    let consentConfirmedAt: Date?
    let consentScope: String?
    let captureProfile: String?
    let captureMarkerCount: Int?
    let artifacts: [ArtifactResponse]
}

struct FeedbackResponse: Decodable {
    let id: String
    let targetType: String
    let targetId: String
    let teacherName: String
    let createdAt: Date
    let status: String
    let commentsText: String
    let markers: [MarkerResponse]
}

struct MarkerResponse: Decodable {
    let id: String
    let timeSeconds: Int
    let text: String
}

struct CaptureMarkerResponse: Decodable {
    let id: String
    let entryId: String
    let artifactId: String
    let studentId: String
    let timeSeconds: Int
    let kind: String
    let note: String?
    let createdAt: Date
}
