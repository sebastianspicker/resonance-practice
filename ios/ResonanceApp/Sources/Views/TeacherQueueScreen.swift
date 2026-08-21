import SwiftUI

// Owns teacher queue loading, pagination, cursor de-duplication, and selected submission state.

struct TeacherQueueConfiguration {
    let courseId: String
    let screenshotQueue: [ReviewQueueEntry]?
    let initiallyQueuedFeedback: Set<String>
    let presentation: TeacherQueuePresentation
    let initialSelectedEntryID: String?
    let initialFeedbackContent: ScreenshotFeedbackContent?
    let selectsInitialSubmission: Bool
}

struct TeacherQueueScreen: View {
    let courseId: String
    let screenshotQueue: [ReviewQueueEntry]?
    let presentation: TeacherQueuePresentation
    let initialSelectedEntryID: String?
    let initialFeedbackContent: ScreenshotFeedbackContent?
    let selectsInitialSubmission: Bool
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @State var queue: [ReviewQueueEntry] = []
    @State var selected: ReviewQueueEntry?
    @State var isLoading = false
    @State var errorMessage: String?
    @State var queuedFeedback: Set<String>

    init(configuration: TeacherQueueConfiguration) {
        courseId = configuration.courseId
        screenshotQueue = configuration.screenshotQueue
        presentation = configuration.presentation
        initialSelectedEntryID = configuration.initialSelectedEntryID
        initialFeedbackContent = configuration.initialFeedbackContent
        selectsInitialSubmission = configuration.selectsInitialSubmission
        _queue = State(initialValue: configuration.screenshotQueue ?? [])
        _queuedFeedback = State(initialValue: configuration.initiallyQueuedFeedback)
    }

    var body: some View {
        TeacherQueuePresentationSurface(
            presentation: presentation, queue: queue, screenshotQueue: screenshotQueue,
            selectsInitialSubmission: selectsInitialSubmission,
            initialSelectedEntryID: initialSelectedEntryID, selected: $selected,
            refreshQueue: refreshQueue, listContent: listBody, workspaceContent: workspaceBody
        )
    }

    func refreshQueue() async {
        guard let session = authManager.session else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let firstPage = try await appState.apiClient.fetchReviewQueue(
                accessToken: session.accessToken, courseId: courseId, limit: 50
            )
            queue = firstPage.items
            var cursor = firstPage.nextCursor
            var seen = Set<String>()
            while let next = cursor, seen.insert(next).inserted {
                let page = try await appState.apiClient.fetchReviewQueue(
                    accessToken: session.accessToken, courseId: courseId, limit: 50, cursor: next
                )
                queue.append(contentsOf: page.items)
                cursor = page.nextCursor
            }
            if selected == nil || !queue.contains(where: { $0.id == selected?.id }) {
                selected = queue.first
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
