import SwiftUI

// List presentation for compact teacher review queue (phone / sheet flow).

extension TeacherQueueView {
    var listBody: some View {
        Group {
            if isLoading && queue.isEmpty {
                ProgressView("Loading submissions…")
            } else if queue.isEmpty {
                ContentUnavailableView(
                    "Nothing to review",
                    systemImage: "checkmark.circle",
                    description: Text("New submissions will appear here.")
                )
            } else {
                List(queue) { entry in
                    Button { selected = entry } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.studentName).font(.headline)
                                Spacer(minLength: 8)
                                StatusPill(
                                    status: queuedFeedback.contains(entry.id) ? .feedbackQueued : .submitted
                                )
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
                        "\(entry.studentName), \(entry.goalText), \(queuedFeedback.contains(entry.id) ? LifecycleStatus.feedbackQueued.label : LifecycleStatus.submitted.label)"
                    )
                    .accessibilityHint("Opens the submission and media player")
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
                    Button("Retry") { Task { await refreshQueue() } }
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
                onFeedbackQueued: { queuedFeedback.insert(entry.id) },
                isFeedbackQueued: queuedFeedback.contains(entry.id)
            )
        }
    }
}
