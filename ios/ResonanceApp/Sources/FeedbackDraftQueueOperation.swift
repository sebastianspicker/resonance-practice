import Foundation
import SwiftData

// Validates and persists one teacher feedback draft before it enters durable sync.

enum FeedbackDraftValidationError: LocalizedError {
    case invalidMarkerTime
    case emptyMarkerNote

    var errorDescription: String? {
        switch self {
        case .invalidMarkerTime:
            return "Enter marker times as minutes and seconds, for example 01:24."
        case .emptyMarkerNote:
            return "Add a note to every marker."
        }
    }
}

@MainActor
struct FeedbackDraftQueueOperation {
    let entry: ReviewQueueEntry
    let teacherName: String
    let status: FeedbackStatus
    let commentsText: String
    let markers: [MarkerDraft]

    func validate() throws {
        _ = try validatedMarkers()
    }

    func persist(in modelContext: ModelContext, syncManager: SyncManager) throws {
        let parsedMarkers = try validatedMarkers()
        let feedbackID = UUID().uuidString
        let feedback = LocalFeedback(
            id: feedbackID,
            targetType: "entry",
            targetId: entry.id,
            teacherName: teacherName,
            status: status,
            commentsText: commentsText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        for marker in parsedMarkers {
            let localMarker = LocalMarker(id: UUID().uuidString, timeSeconds: marker.seconds, text: marker.text)
            modelContext.insert(localMarker)
            feedback.markers.append(localMarker)
        }
        modelContext.insert(feedback)
        try modelContext.save()
        syncManager.enqueue(type: .postFeedback, payload: [
            "targetType": "entry",
            "targetId": entry.id,
            "feedbackId": feedbackID
        ])
    }

    private func validatedMarkers() throws -> [(seconds: Int, text: String)] {
        try markers.compactMap { marker in
            guard !marker.time.isEmpty || !marker.text.isEmpty else { return nil }
            guard let seconds = FeedbackEditorView.parse(marker.time) else {
                throw FeedbackDraftValidationError.invalidMarkerTime
            }
            guard !marker.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FeedbackDraftValidationError.emptyMarkerNote
            }
            return (seconds, marker.text)
        }
    }
}
