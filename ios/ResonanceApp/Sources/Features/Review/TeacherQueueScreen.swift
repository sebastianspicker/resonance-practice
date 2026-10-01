import SwiftUI

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
    private enum QueueLoadKind {
        case refresh
        case nextPage
    }

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
    @State private var refreshRequestID: UUID?
    @State private var nextPageRequestID: UUID?
    @State var errorMessage: String?
    @State private var nextCursor: String?
    @State private var loadGeneration = 0
    @State private var failedLoad: QueueLoadKind?
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
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestID = UUID()
        refreshRequestID = requestID
        isLoading = true
        errorMessage = nil
        failedLoad = nil
        defer {
            if refreshRequestID == requestID {
                refreshRequestID = nil
                isLoading = false
            }
        }
        do {
            let firstPage = try await appState.apiClient.fetchReviewQueue(
                accessToken: session.accessToken, courseId: courseId, limit: 50
            )
            try Task.checkCancellation()
            guard isCurrentLoad(generation, session: session) else { return }
            let selectedID = selected?.id
            queue = firstPage.items
            nextCursor = firstPage.nextCursor?.isEmpty == false ? firstPage.nextCursor : nil
            selected = selectedID.flatMap { id in queue.first { $0.id == id } } ?? queue.first
        } catch {
            guard isCurrentLoad(generation, session: session) else { return }
            errorMessage = error.localizedDescription
            failedLoad = .refresh
        }
    }

    func loadNextQueuePage() async {
        guard let session = authManager.session,
              let cursor = nextCursor,
              !cursor.isEmpty,
              nextPageRequestID == nil
        else { return }
        let generation = loadGeneration
        let requestID = UUID()
        nextPageRequestID = requestID
        errorMessage = nil
        failedLoad = nil
        defer {
            if nextPageRequestID == requestID {
                nextPageRequestID = nil
            }
        }
        do {
            let page = try await appState.apiClient.fetchReviewQueue(
                accessToken: session.accessToken, courseId: courseId, limit: 50, cursor: cursor
            )
            try Task.checkCancellation()
            guard isCurrentLoad(generation, session: session), nextCursor == cursor else { return }
            let existingIDs = Set(queue.map(\.id))
            queue.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
            nextCursor = page.nextCursor?.isEmpty == false ? page.nextCursor : nil
        } catch {
            guard isCurrentLoad(generation, session: session), nextCursor == cursor else { return }
            errorMessage = error.localizedDescription
            failedLoad = .nextPage
        }
    }

    func retryQueueLoad() async {
        switch failedLoad {
        case .nextPage: await loadNextQueuePage()
        case .refresh, nil: await refreshQueue()
        }
    }

    var hasNextQueuePage: Bool { nextCursor != nil }

    var isLoadingNextPage: Bool { nextPageRequestID != nil }

    private func isCurrentLoad(_ generation: Int, session: AuthSession) -> Bool {
        generation == loadGeneration &&
            authManager.session?.userId == session.userId &&
            authManager.session?.accessToken == session.accessToken
    }
}
