import SwiftUI

// Loads a teacher's review queue and presents it as a list or a review workspace.

extension ReviewQueueEntry: Identifiable {}
extension ArtifactResponse: Identifiable {}

enum TeacherQueuePresentation: Equatable {
    case list
    case workspace
}

struct TeacherQueueView: View {
    private enum QueueLoadKind {
        case refresh
        case nextPage
    }

    let courseId: String
    /// Which submissions to list: the open queue or already reviewed work.
    let reviewStatus: ReviewQueueStatus
    /// A fixed local queue that replaces the remote queue load when present.
    let presetQueue: [ReviewQueueEntry]?
    let presentation: TeacherQueuePresentation
    let initialSelectedEntryID: String?
    let initialFeedback: FeedbackPrefill?
    let selectsInitialSubmission: Bool
    @Environment(\.apiClient) var apiClient
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
    /// Entry whose feedback editor holds unsent text.
    @State var draftEntryID: String?
    /// Row the user picked while a draft was open; applied only after they confirm discarding.
    @State var pendingSelection: ReviewQueueEntry?

    init(
        courseId: String,
        reviewStatus: ReviewQueueStatus = .submitted,
        presetQueue: [ReviewQueueEntry]? = nil,
        initiallyQueuedFeedback: Set<String> = [],
        presentation: TeacherQueuePresentation = .list,
        initialSelectedEntryID: String? = nil,
        initialFeedback: FeedbackPrefill? = nil,
        selectsInitialSubmission: Bool = true
    ) {
        self.courseId = courseId
        self.reviewStatus = reviewStatus
        self.presetQueue = presetQueue
        self.presentation = presentation
        self.initialSelectedEntryID = initialSelectedEntryID
        self.initialFeedback = initialFeedback
        self.selectsInitialSubmission = selectsInitialSubmission
        _queue = State(initialValue: presetQueue ?? [])
        _queuedFeedback = State(initialValue: initiallyQueuedFeedback)
    }

    var body: some View {
        TeacherQueuePresentationSurface(
            presentation: presentation, queue: queue, presetQueue: presetQueue,
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
            let firstPage = try await apiClient.fetchReviewQueue(
                accessToken: session.accessToken, courseId: courseId, status: reviewStatus,
                limit: 50
            )
            try Task.checkCancellation()
            guard isCurrentLoad(generation, session: session) else { return }
            let selectedID = selected?.id
            queue = firstPage.items
            nextCursor = firstPage.nextCursor?.isEmpty == false ? firstPage.nextCursor : nil
            // A refresh must not swap the entry out from under an unsent draft.
            if draftEntryID == nil {
                selected = selectedID.flatMap { id in queue.first { $0.id == id } }
                    ?? (presentation == .workspace && selectsInitialSubmission ? queue.first : nil)
            }
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
            let page = try await apiClient.fetchReviewQueue(
                accessToken: session.accessToken, courseId: courseId, status: reviewStatus,
                limit: 50, cursor: cursor
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

    /// Status shown for a listed submission.
    func listStatus(for entry: ReviewQueueEntry) -> LifecycleStatus {
        if reviewStatus == .reviewed { return .reviewed }
        return queuedFeedback.contains(entry.id) ? .feedbackQueued : .submitted
    }

    var isLoadingNextPage: Bool { nextPageRequestID != nil }

    private func isCurrentLoad(_ generation: Int, session: AuthSession) -> Bool {
        generation == loadGeneration &&
            authManager.session?.userId == session.userId &&
            authManager.session?.accessToken == session.accessToken
    }
}
