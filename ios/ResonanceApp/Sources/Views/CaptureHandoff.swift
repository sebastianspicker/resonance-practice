import Foundation

// Capture marker drafts and the immutable lesson-video handoff result.

struct CaptureMarkerDraft: Identifiable {
    let id: String
    let timeSeconds: Int
    let kind: CaptureMarkerKind
    let note: String?
}

/// Immutable handoff emitted only after recording has produced a usable local file.
struct TeachingLessonCaptureResult {
    let videoURL: URL
    let captureProfile: CaptureProfile
    let markers: [CaptureMarkerDraft]
    let durationSeconds: Int
}
