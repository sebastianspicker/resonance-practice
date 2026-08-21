import SwiftUI

// Selects the teacher feedback presentation while keeping both layouts explicit.

struct FeedbackEditorSurface: View {
    let presentation: FeedbackEditorPresentation
    let entry: ReviewQueueEntry
    @Binding var status: FeedbackStatus
    @Binding var commentsText: String
    @Binding var markers: [MarkerDraft]
    let isSending: Bool
    @Binding var validationMessage: String?
    let statusHint: String
    let addMarker: () -> Void
    let removeMarker: (UUID) -> Void
    let cancel: () -> Void
    let send: () -> Void

    var body: some View {
        let draft = FeedbackEditorDraft(
            status: $status,
            commentsText: $commentsText,
            markers: $markers,
            isSending: isSending,
            validationMessage: $validationMessage,
            statusHint: statusHint,
            addMarker: addMarker,
            removeMarker: removeMarker,
            send: send
        )
        switch presentation {
        case .form:
            FeedbackEditorForm(
                entry: entry,
                draft: draft,
                cancel: cancel
            )
        case .workspace:
            FeedbackEditorWorkspace(draft: draft)
        }
    }
}

private struct FeedbackEditorDraft {
    let status: Binding<FeedbackStatus>
    let commentsText: Binding<String>
    let markers: Binding<[MarkerDraft]>
    let isSending: Bool
    let validationMessage: Binding<String?>
    let statusHint: String
    let addMarker: () -> Void
    let removeMarker: (UUID) -> Void
    let send: () -> Void
}

private struct FeedbackEditorForm: View {
    let entry: ReviewQueueEntry
    let draft: FeedbackEditorDraft
    let cancel: () -> Void
    @FocusState private var commentsFocused: Bool

    var body: some View {
        Form {
            Section("Submission") {
                LabeledContent("Student", value: entry.studentName)
                Text(entry.goalText)
                if let notes = entry.notes, !notes.isEmpty {
                    LabeledContent("Reflection", value: notes)
                }
            }

            Section("Outcome") {
                Picker("Outcome", selection: draft.status) {
                    Text(FeedbackStatus.accepted.displayLabel).tag(FeedbackStatus.accepted)
                    Text(FeedbackStatus.needsRevision.displayLabel).tag(FeedbackStatus.needsRevision)
                    Text(FeedbackStatus.nextGoal.displayLabel).tag(FeedbackStatus.nextGoal)
                }
                .pickerStyle(.menu)
                Text(draft.statusHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                TextField("Comments", text: draft.commentsText, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($commentsFocused)
                if let validationMessage = draft.validationMessage.wrappedValue {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Validation error: \(validationMessage)")
                }
            }

            Section("Timestamped markers") {
                ForEach(draft.markers) { $marker in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading) {
                            TextField("Time (mm:ss)", text: $marker.time)
                                .textContentType(.none)
                                .keyboardType(.numbersAndPunctuation)
                            TextField("Marker note", text: $marker.text, axis: .vertical)
                        }
                        Button("Delete marker", systemImage: "trash") { draft.removeMarker(marker.id) }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Add marker at current playback time", systemImage: "plus", action: draft.addMarker)
            }
        }
        .navigationTitle("Feedback")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.isSending ? "Queueing…" : "Send feedback", action: draft.send)
                    .disabled(draft.commentsText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.isSending)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { commentsFocused = false }
            }
        }
    }
}

private struct FeedbackEditorWorkspace: View {
    let draft: FeedbackEditorDraft
    @FocusState private var commentsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Feedback").font(.headline.weight(.semibold))
                    FeedbackEditorWorkspaceOutcome(status: draft.status, statusHint: draft.statusHint)
                    FeedbackEditorWorkspaceComments(
                        commentsText: draft.commentsText,
                        validationMessage: draft.validationMessage,
                        commentsFocused: $commentsFocused
                    )
                    FeedbackEditorWorkspaceMarkers(
                        markers: draft.markers,
                        addMarker: draft.addMarker,
                        removeMarker: draft.removeMarker
                    )
                }
                .padding(24)
            }
            WorkspaceRule()
            FeedbackEditorWorkspaceFooter(
                isSending: draft.isSending,
                commentsText: draft.commentsText.wrappedValue,
                send: draft.send
            )
        }
        .background(AppTheme.workspacePanel)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { commentsFocused = false }
            }
        }
    }
}

private struct FeedbackEditorWorkspaceOutcome: View {
    @Binding var status: FeedbackStatus
    let statusHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkspaceSectionLabel(title: "Outcome")
            HStack(spacing: 0) {
                outcomeButton(FeedbackStatus.accepted.displayLabel, status: .accepted)
                outcomeButton(FeedbackStatus.needsRevision.displayLabel, status: .needsRevision)
                outcomeButton(FeedbackStatus.nextGoal.displayLabel, status: .nextGoal)
            }
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .stroke(AppTheme.workspaceBorder)
            )
            Text(statusHint).font(.footnote).foregroundStyle(AppTheme.workspaceMuted)
        }
    }

    private func outcomeButton(_ title: String, status candidate: FeedbackStatus) -> some View {
        Button(title) { status = candidate }
            .font(.caption.weight(.medium))
            .foregroundStyle(status == candidate ? AppTheme.accent : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(status == candidate ? AppTheme.selection : .clear)
            .accessibilityLabel(title)
            .accessibilityAddTraits(status == candidate ? .isSelected : [])
    }
}

private struct FeedbackEditorWorkspaceComments: View {
    @Binding var commentsText: String
    @Binding var validationMessage: String?
    @FocusState.Binding var commentsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceSectionLabel(title: "Feedback")
            FeedbackEditorWorkspaceCard(padding: 12) {
                TextField("Concrete feedback", text: $commentsText, axis: .vertical)
                    .lineLimit(6...12)
                    .focused($commentsFocused)
            }
            .accessibilityLabel("Feedback")
            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Validation error: \(validationMessage)")
                }
                Spacer()
                Text("\(commentsText.count) / 1000")
            }
            .font(.caption).foregroundStyle(AppTheme.workspaceMuted)
        }
    }
}

private struct FeedbackEditorWorkspaceMarkers: View {
    @Binding var markers: [MarkerDraft]
    let addMarker: () -> Void
    let removeMarker: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceSectionLabel(title: "Markers")
            ForEach($markers) { $marker in
                FeedbackEditorWorkspaceCard(padding: 10) {
                    HStack(spacing: 8) {
                        TextField("01:24", text: $marker.time)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.subheadline.monospacedDigit())
                            .frame(width: 78)
                        TextField("Note", text: $marker.text)
                        Button("Delete marker", systemImage: "trash") { removeMarker(marker.id) }
                            .labelStyle(.iconOnly).foregroundStyle(AppTheme.workspaceMuted)
                    }
                }
            }
            Button("Add marker at current position", systemImage: "plus", action: addMarker)
                .buttonStyle(.bordered)
                .tint(AppTheme.accent)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct FeedbackEditorWorkspaceFooter: View {
    let isSending: Bool
    let commentsText: String
    let send: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Private to this course · not shared publicly")
                    .font(.caption)
                    .foregroundStyle(AppTheme.workspaceMuted)
                Text("Queued safely when offline")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.workspaceMuted.opacity(0.85))
            }
            Spacer(minLength: 8)
            Button(isSending ? "Queueing…" : "Send feedback", action: send)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accentStrong)
                .disabled(commentsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(18)
    }
}

private struct FeedbackEditorWorkspaceCard<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(
                AppTheme.workspaceRaised,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .stroke(AppTheme.workspaceBorder)
            )
    }
}
