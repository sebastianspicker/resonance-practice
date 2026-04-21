import SwiftUI

extension ReviewQueueEntry: Identifiable {}


struct TeacherQueueView: View {
    let courseId: String
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @State private var queue: [ReviewQueueEntry] = []
    @State private var selected: ReviewQueueEntry?
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading && queue.isEmpty {
                ProgressView("Loading queue…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if queue.isEmpty {
                ContentUnavailableView(
                    "No submissions",
                    systemImage: "checkmark.circle",
                    description: Text("All submitted entries have been reviewed.")
                )
            } else {
                List(queue) { entry in
                    Button {
                        selected = entry
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.studentName)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Text(entry.goalText)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                            HStack {
                                Text(entry.practiceDate, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.65))
                                Text("• \(entry.artifacts.count) artifacts")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        .padding(.leading, 20)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(entry.studentName), \(entry.goalText), \(entry.artifacts.count) artifacts")
                    .accessibilityHint("Double-tap to review this submission")
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    .listRowBackground(Color.white.opacity(0.08).cornerRadius(12).padding(.vertical, 4))
                }
                .scrollContentBackground(.hidden)
                .safeAreaPadding(.horizontal, 8)
                .listStyle(.plain)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") { Task { await refreshQueue() } }
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh review queue")
                    .accessibilityHint("Double-tap to reload submissions awaiting review")
            }
        }
        .task { await refreshQueue() }
        .sheet(item: $selected) { entry in
            FeedbackEditorView(entry: entry)
        }
    }

    private func refreshQueue() async {
        guard let session = authManager.session else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var loadedQueue: [ReviewQueueEntry] = []
            var cursor: String?
            var seenCursors = Set<String>()

            while true {
                let response = try await appState.apiClient.fetchReviewQueue(
                    accessToken: session.accessToken,
                    courseId: courseId,
                    limit: 50,
                    cursor: cursor
                )
                loadedQueue.append(contentsOf: response.items)

                guard let nextCursor = response.nextCursor, nextCursor.isEmpty == false else {
                    break
                }
                guard seenCursors.insert(nextCursor).inserted else {
                    break
                }
                cursor = nextCursor
            }

            queue = loadedQueue
        } catch {
            appState.reportError(error)
        }
    }
}
