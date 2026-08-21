import Foundation

/// Feedback payload whose optional local ID becomes the server idempotency key.
struct FeedbackSubmission {
    let feedbackId: String?
    let targetType: String
    let targetId: String
    let status: FeedbackStatus
    let commentsText: String
    let markers: [LocalMarker]
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
