import SwiftUI

// Workspace (iPad) presentation: queue pane + selected submission review.

extension TeacherQueueScreen {
    @ViewBuilder var workspaceBody: some View {
        if isLoading && queue.isEmpty {
            ProgressView("Loading submissions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if queue.isEmpty {
            ContentUnavailableView(
                "Nothing to review",
                systemImage: "checkmark.circle",
                description: Text("New submissions will appear here.")
            )
        } else {
            HStack(spacing: 0) {
                workspaceQueuePane
                    .frame(width: 260)
                WorkspaceDivider()
                if let selected {
                    WorkspaceReviewDetail(
                        entry: selected,
                        initialFeedbackContent: initialFeedbackContent,
                        onFeedbackQueued: { queuedFeedback.insert(selected.id) },
                        isFeedbackQueued: queuedFeedback.contains(selected.id)
                    )
                    .id(selected.id)
                } else {
                    ContentUnavailableView("Select a submission", systemImage: "waveform")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    var workspaceQueuePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("To review")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.workspaceInk)
                Spacer(minLength: 0)
                Text("\(queue.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppTheme.selection, in: Capsule())
                    .accessibilityLabel("\(queue.count) submissions to review")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refreshQueue() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.workspaceMuted)
                .disabled(isLoading)
                .accessibilityLabel("Refresh review queue")
            }
            .padding(.horizontal, 18)
            .frame(height: 74)
            WorkspaceRule()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue) { entry in
                        let isSelected = entry.id == selected?.id
                        let isQueued = queuedFeedback.contains(entry.id)
                        Button { selected = entry } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.goalText)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.workspaceInk)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(queueMetadata(entry))
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.workspaceMuted)
                                    .lineLimit(1)
                                StatusPill(status: isQueued ? .feedbackQueued : .submitted)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isSelected ? AppTheme.selection : .clear)
                            .overlay(alignment: .leading) {
                                if isSelected {
                                    Rectangle()
                                        .fill(AppTheme.accent)
                                        .frame(width: 3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(entry.studentName), \(entry.goalText), "
                                + (isQueued
                                    ? LifecycleStatus.feedbackQueued.label
                                    : LifecycleStatus.submitted.label)
                        )
                        .accessibilityValue(isSelected ? "Selected" : "")
                        .accessibilityHint("Opens the submission and feedback editor")
                        WorkspaceRule()
                    }
                }
            }
            .refreshable { await refreshQueue() }

            if let errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AppTheme.statusFailedForeground)
                    Text(errorMessage).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Retry") { Task { await refreshQueue() } }
                }
                .font(.caption)
                .padding(12)
                .background(AppTheme.workspaceRaised)
            }
        }
        .background(AppTheme.workspaceSidebar)
    }
}
