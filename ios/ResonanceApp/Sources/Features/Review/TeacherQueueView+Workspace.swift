import SwiftUI

// Workspace (iPad) presentation: queue pane + selected submission review.

extension TeacherQueueScreen {
    @ViewBuilder var workspaceBody: some View {
        if isLoading && queue.isEmpty {
            HStack(spacing: 0) {
                workspaceLoadingQueuePane
                    .frame(width: 300)
                WorkspaceDivider()
                ContentUnavailableView("Loading submissions", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if queue.isEmpty {
            ContentUnavailableView(
                "Nothing to review",
                systemImage: "checkmark.circle",
                description: Text("New submissions will appear here.")
            )
        } else {
            HStack(spacing: 0) {
                workspaceQueuePane
                    .frame(width: 300)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("To review")
                        .font(AppTheme.editorialGoal)
                    Text("Private course submissions")
                        .font(.caption)
                        .foregroundStyle(AppTheme.workspaceMuted)
                }
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
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.studentName)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer(minLength: 0)
                                    Text(entry.practiceDate, style: .time)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(AppTheme.workspaceMuted)
                                }
                                Text(entry.goalText)
                                    .font(.system(.subheadline, design: .serif))
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
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isSelected ? AppTheme.selection : .clear,
                                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                            )
                            .overlay {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                                        .stroke(AppTheme.accent, lineWidth: 1)
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
                    if hasNextQueuePage {
                        queuePaginationControl
                            .padding(.vertical, 14)
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
                    Button("Retry") { Task { await retryQueueLoad() } }
                }
                .font(.caption)
                .padding(12)
                .background(AppTheme.workspaceRaised)
            }
        }
        .background(AppTheme.workspaceSidebar)
    }

    private var workspaceLoadingQueuePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("To review")
                    .font(AppTheme.editorialGoal)
                Text("Private course submissions")
                    .font(.caption)
                    .foregroundStyle(AppTheme.workspaceMuted)
            }
            .foregroundStyle(AppTheme.workspaceInk)
            .padding(.horizontal, 18)
            .frame(height: 74, alignment: .leading)
            WorkspaceRule()

            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { _ in
                    WorkspaceQueueSkeletonRow()
                    WorkspaceRule()
                }
            }
            Spacer()
        }
        .background(AppTheme.workspaceSidebar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading submissions")
    }
}

private struct WorkspaceQueueSkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(AppTheme.workspaceBorderStrong)
                .frame(width: 104, height: 12)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(AppTheme.workspaceBorder)
                .frame(maxWidth: .infinity)
                .frame(height: 14)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(AppTheme.workspaceBorder)
                .frame(width: 138, height: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
