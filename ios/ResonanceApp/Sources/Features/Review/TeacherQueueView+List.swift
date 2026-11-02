import SwiftUI

// List presentation for compact teacher review queue (phone / sheet flow).

extension TeacherQueueView {
    var listBody: some View {
        Group {
            if isLoading && queue.isEmpty {
                ProgressView("Loading submissions…")
            } else if queue.isEmpty {
                if reviewStatus == .reviewed {
                    ContentUnavailableView(
                        "No reviewed submissions",
                        systemImage: "checkmark.circle",
                        description: Text("Submissions you have reviewed will appear here.")
                    )
                } else {
                    ContentUnavailableView(
                        "Nothing to review",
                        systemImage: "checkmark.circle",
                        description: Text("New submissions will appear here.")
                    )
                }
            } else {
                List {
                    ForEach(queue) { entry in
                        Button { selected = entry } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.studentName).font(.headline)
                                    Spacer(minLength: 8)
                                    StatusPill(status: listStatus(for: entry))
                                }
                                Text(entry.goalText).foregroundStyle(.primary).lineLimit(2)
                                Text(listMetadata(entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(entry.studentName), \(entry.goalText), "
                                + listStatus(for: entry).label
                        )
                        .accessibilityHint("Opens the submission and media player")
                    }
                    if hasNextQueuePage { queuePaginationControl }
                }
                .scrollContentBackground(.hidden)
                .background(AppTheme.workspaceBackground)
                .refreshable { await refreshQueue() }
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage {
                HStack {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Retry") { Task { await retryQueueLoad() } }
                }
                .padding()
                .background(.bar)
            }
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshQueue() } }
                .disabled(isLoading)
                .accessibilityLabel("Refresh review queue")
        }
        .sheet(item: $selected) { entry in
            SubmissionDetailView(
                entry: entry,
                onFeedbackQueued: { feedbackQueued(for: entry) },
                isFeedbackQueued: queuedFeedback.contains(entry.id),
                reviewStatus: reviewStatus,
                onDraftChange: { draftChanged($0, for: entry) }
            )
        }
    }
}

extension TeacherQueueView {
    @ViewBuilder var queuePaginationControl: some View {
        HStack {
            Spacer()
            if isLoadingNextPage {
                ProgressView("Loading more submissions…")
            } else {
                Button("Load more submissions") { Task { await loadNextQueuePage() } }
            }
            Spacer()
        }
        .disabled(isLoading)
        .accessibilityHint("Loads the next 50 submissions")
    }
}
