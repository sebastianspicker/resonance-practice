import SwiftUI

// Stable navigation entrypoint for a teacher's review queue.

extension ReviewQueueEntry: Identifiable {}
extension ArtifactResponse: Identifiable {}

enum TeacherQueuePresentation: Equatable {
    case list
    case workspace
}

struct TeacherQueueView: View {
    private let configuration: TeacherQueueConfiguration

    init(
        courseId: String,
        screenshotQueue: [ReviewQueueEntry]? = nil,
        initiallyQueuedFeedback: Set<String> = [],
        presentation: TeacherQueuePresentation = .list,
        initialSelectedEntryID: String? = nil,
        initialFeedbackContent: ScreenshotFeedbackContent? = nil,
        selectsInitialSubmission: Bool = true
    ) {
        configuration = TeacherQueueConfiguration(
            courseId: courseId, screenshotQueue: screenshotQueue,
            initiallyQueuedFeedback: initiallyQueuedFeedback, presentation: presentation,
            initialSelectedEntryID: initialSelectedEntryID,
            initialFeedbackContent: initialFeedbackContent,
            selectsInitialSubmission: selectsInitialSubmission
        )
    }

    var body: some View {
        TeacherQueueScreen(configuration: configuration)
    }
}
