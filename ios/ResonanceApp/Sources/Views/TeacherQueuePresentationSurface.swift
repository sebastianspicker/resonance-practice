import SwiftUI

// Chooses the teacher queue's list or workspace surface and initializes selection consistently.

struct TeacherQueuePresentationSurface<ListContent: View, WorkspaceContent: View>: View {
    let presentation: TeacherQueuePresentation
    let queue: [ReviewQueueEntry]
    let screenshotQueue: [ReviewQueueEntry]?
    let selectsInitialSubmission: Bool
    let initialSelectedEntryID: String?
    @Binding var selected: ReviewQueueEntry?
    let refreshQueue: () async -> Void
    let listContent: ListContent
    let workspaceContent: WorkspaceContent

    var body: some View {
        Group {
            if presentation == .workspace {
                workspaceContent
            } else {
                listContent
            }
        }
        .task {
            await loadInitialQueueState()
        }
    }

    private func loadInitialQueueState() async {
        if screenshotQueue == nil {
            await refreshQueue()
        } else if selectsInitialSubmission, selected == nil {
            selected = queue.first { $0.id == initialSelectedEntryID } ?? queue.first
        }
    }
}

extension TeacherQueueScreen {
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
}

extension TeacherQueueView {
    static func kindDisplayName(_ kind: String?) -> String { TeacherQueueScreen.kindDisplayName(kind) }
    static func totalDurationLabel(for entry: ReviewQueueEntry) -> String {
        TeacherQueueScreen.totalDurationLabel(for: entry)
    }
}
