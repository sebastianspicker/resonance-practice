import SwiftUI

// Presents a teacher's review queue and routes selected submissions into feedback workflows.

extension ReviewQueueEntry: Identifiable {}
extension ArtifactResponse: Identifiable {}

enum TeacherQueuePresentation: Equatable {
    case list
    case workspace
}

struct TeacherQueueView: View {
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

    init(
        courseId: String,
        screenshotQueue: [ReviewQueueEntry]? = nil,
        initiallyQueuedFeedback: Set<String> = [],
        presentation: TeacherQueuePresentation = .list,
        initialSelectedEntryID: String? = nil,
        initialFeedbackContent: ScreenshotFeedbackContent? = nil,
        selectsInitialSubmission: Bool = true
    ) {
        self.courseId = courseId
        self.screenshotQueue = screenshotQueue
        self.presentation = presentation
        self.initialSelectedEntryID = initialSelectedEntryID
        self.initialFeedbackContent = initialFeedbackContent
        self.selectsInitialSubmission = selectsInitialSubmission
        _queue = State(initialValue: screenshotQueue ?? [])
        _queuedFeedback = State(initialValue: initiallyQueuedFeedback)
    }

    var body: some View {
        Group {
            if presentation == .workspace {
                workspaceBody
            } else {
                listBody
            }
        }
        .task {
            if screenshotQueue == nil {
                await refreshQueue()
            } else if selectsInitialSubmission, selected == nil {
                selected = queue.first { $0.id == initialSelectedEntryID } ?? queue.first
            }
        }
    }

    func queueMetadata(_ entry: ReviewQueueEntry) -> String {
        let kindLabel = Self.kindDisplayName(entry.kind)
        let duration = Self.totalDurationLabel(for: entry)
        return "\(entry.studentName) · \(kindLabel) · \(duration)"
    }

    func listMetadata(_ entry: ReviewQueueEntry) -> String {
        let count = entry.artifacts.count
        let items = count == 1 ? "1 evidence item" : "\(count) evidence items"
        return "\(items) · \(entry.practiceDate.formatted(date: .abbreviated, time: .omitted))"
    }

    static func kindDisplayName(_ kind: String?) -> String {
        switch kind {
        case EntryKind.teachingLesson.rawValue: return "Teaching lesson"
        case EntryKind.practice.rawValue, nil: return "Practice"
        default: return kind?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Practice"
        }
    }

    static func totalDurationLabel(for entry: ReviewQueueEntry) -> String {
        let total = entry.artifacts.reduce(0) { $0 + $1.durationSeconds }
        guard total > 0 else { return "—" }
        let minutes = total / 60
        let seconds = total % 60
        if minutes >= 60 {
            return String(format: "%dh %02dm", minutes / 60, minutes % 60)
        }
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        return String(format: "0:%02d", seconds)
    }

    func refreshQueue() async {
        guard let session = authManager.session else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let firstPage = try await appState.apiClient.fetchReviewQueue(
                accessToken: session.accessToken,
                courseId: courseId,
                limit: 50
            )
            queue = firstPage.items
            var cursor = firstPage.nextCursor
            var seen = Set<String>()
            while let next = cursor, seen.insert(next).inserted {
                let page = try await appState.apiClient.fetchReviewQueue(
                    accessToken: session.accessToken,
                    courseId: courseId,
                    limit: 50,
                    cursor: next
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
