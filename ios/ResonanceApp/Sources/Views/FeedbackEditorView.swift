import SwiftUI

// Captures structured teacher feedback and enqueues it for durable synchronization.

struct MarkerDraft: Identifiable, Equatable {
    let id = UUID()
    var time: String
    var text: String
}

enum FeedbackEditorPresentation: Equatable {
    case form
    case workspace
}

struct FeedbackEditorView: View {
    let entry: ReviewQueueEntry
    var playbackTime: () -> TimeInterval = { 0 }
    var onQueued: (() -> Void)?
    private let presentation: FeedbackEditorPresentation

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var syncManager: SyncManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var status: FeedbackStatus = .accepted
    @State private var commentsText = ""
    @State private var markers: [MarkerDraft] = []
    @State private var isSending = false
    @State private var validationMessage: String?
    @State private var confirmDiscard = false
    @FocusState private var commentsFocused: Bool

    init(
        entry: ReviewQueueEntry,
        playbackTime: @escaping () -> TimeInterval = { 0 },
        onQueued: (() -> Void)? = nil,
        initialContent: ScreenshotFeedbackContent? = nil,
        presentation: FeedbackEditorPresentation = .form
    ) {
        self.entry = entry
        self.playbackTime = playbackTime
        self.onQueued = onQueued
        self.presentation = presentation
        _status = State(initialValue: initialContent?.status ?? .accepted)
        _commentsText = State(initialValue: initialContent?.commentsText ?? "")
        _markers = State(initialValue: initialContent?.markers ?? [])
    }

    init(
        entry: ReviewQueueEntry,
        playbackTime: @escaping () -> TimeInterval = { 0 },
        onQueued: (() -> Void)? = nil,
        initialContent: ScreenshotFeedbackContent? = nil
    ) {
        self.entry = entry
        self.playbackTime = playbackTime
        self.onQueued = onQueued
        _status = State(initialValue: initialContent?.status ?? .ok)
        _commentsText = State(initialValue: initialContent?.commentsText ?? "")
        _markers = State(initialValue: initialContent?.markers ?? [])
    }

    var body: some View {
        Group {
            if presentation == .workspace {
                workspaceContent
            } else {
                formContent
            }
        }
    }

    private var formContent: some View {
        Form {
            Section("Submission") {
                LabeledContent("Student", value: entry.studentName)
                Text(entry.goalText)
                if let notes = entry.notes, !notes.isEmpty {
                    LabeledContent("Reflection", value: notes)
                }
            }

            Section("Outcome") {
                Picker("Outcome", selection: $status) {
                    Text(FeedbackStatus.accepted.displayLabel).tag(FeedbackStatus.accepted)
                    Text(FeedbackStatus.needsRevision.displayLabel).tag(FeedbackStatus.needsRevision)
                    Text(FeedbackStatus.nextGoal.displayLabel).tag(FeedbackStatus.nextGoal)
                }
                .pickerStyle(.menu)
                Text(statusHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                TextField("Comments", text: $commentsText, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($commentsFocused)
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Validation error: \(validationMessage)")
                }
            }

            Section("Timestamped markers") {
                ForEach($markers) { $marker in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading) {
                            TextField("Time (mm:ss)", text: $marker.time)
                                .textContentType(.none)
                                .keyboardType(.numbersAndPunctuation)
                            TextField("Marker note", text: $marker.text, axis: .vertical)
                        }
                        Button("Delete marker", systemImage: "trash") {
                            markers.removeAll { $0.id == marker.id }
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("Add marker at current playback time", systemImage: "plus") {
                    markers.append(
                        MarkerDraft(time: Self.format(playbackTime()), text: "")
                    )
                }
            }
        }
        .navigationTitle("Feedback")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if hasDraft { confirmDiscard = true } else { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSending ? "Queueing…" : "Send feedback") {
                    queueFeedback()
                }
                .disabled(commentsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { commentsFocused = false }
            }
        }
        .confirmationDialog("Discard unsent feedback?", isPresented: $confirmDiscard) {
            Button("Discard feedback", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your comments and markers have not been queued.")
        }
    }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Feedback").font(.headline.weight(.semibold))

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

                    VStack(alignment: .leading, spacing: 10) {
                        WorkspaceSectionLabel(title: "Feedback")
                        TextField("Concrete feedback", text: $commentsText, axis: .vertical)
                            .lineLimit(6...12)
                            .focused($commentsFocused)
                            .padding(12)
                            .background(
                                AppTheme.workspaceRaised,
                                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                                    .stroke(AppTheme.workspaceBorder)
                            )
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

                    VStack(alignment: .leading, spacing: 10) {
                        WorkspaceSectionLabel(title: "Markers")
                        ForEach($markers) { $marker in
                            HStack(spacing: 8) {
                                TextField("01:24", text: $marker.time)
                                    .keyboardType(.numbersAndPunctuation)
                                    .font(.subheadline.monospacedDigit())
                                    .frame(width: 78)
                                TextField("Note", text: $marker.text)
                                Button("Delete marker", systemImage: "trash") {
                                    markers.removeAll { $0.id == marker.id }
                                }
                                .labelStyle(.iconOnly).foregroundStyle(AppTheme.workspaceMuted)
                            }
                            .padding(10)
                            .background(
                                AppTheme.workspaceRaised,
                                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                                    .stroke(AppTheme.workspaceBorder)
                            )
                        }
                        Button("Add marker at current position", systemImage: "plus") {
                            markers.append(MarkerDraft(time: Self.format(playbackTime()), text: ""))
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.accent)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
            }
            WorkspaceRule()
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
                Button(isSending ? "Queueing…" : "Send feedback", action: queueFeedback)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accentStrong)
                    .disabled(commentsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            .padding(18)
        }
        .background(AppTheme.workspacePanel)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { commentsFocused = false }
            }
        }
        .confirmationDialog("Discard unsent feedback?", isPresented: $confirmDiscard) {
            Button("Discard feedback", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your comments and markers have not been queued.")
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

    private var hasDraft: Bool { !commentsText.isEmpty || !markers.isEmpty }

    private var statusHint: String {
        switch status {
        case .accepted: return "The submitted goal was met."
        case .needsRevision: return "Ask the student to revise this work."
        case .nextGoal: return "Set a concrete next practice goal."
        }
    }

    private func queueFeedback() {
        guard !isSending, authManager.session != nil else { return }
        validationMessage = nil
        let nonEmpty = markers.filter { !$0.time.isEmpty || !$0.text.isEmpty }
        var parsed: [(Int, String)] = []
        for marker in nonEmpty {
            guard let seconds = Self.parse(marker.time) else {
                validationMessage = "Enter marker times as minutes and seconds, for example 01:24."
                return
            }
            guard !marker.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                validationMessage = "Add a note to every marker."
                return
            }
            parsed.append((seconds, marker.text))
        }

        isSending = true
        let feedbackId = UUID().uuidString
        let feedback = LocalFeedback(
            id: feedbackId,
            targetType: "entry",
            targetId: entry.id,
            teacherName: authManager.session?.displayName ?? "",
            status: status,
            commentsText: commentsText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        for item in parsed {
            let marker = LocalMarker(id: UUID().uuidString, timeSeconds: item.0, text: item.1)
            modelContext.insert(marker)
            feedback.markers.append(marker)
        }
        modelContext.insert(feedback)
        do {
            try modelContext.save()
            syncManager.enqueue(type: .postFeedback, payload: [
                "targetType": "entry",
                "targetId": entry.id,
                "feedbackId": feedbackId
            ])
            onQueued?()
            dismiss()
        } catch {
            isSending = false
            appState.reportError(error)
        }
    }

    static func parse(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 { return Int(parts[0]).flatMap { $0 >= 0 ? $0 : nil } }
        guard parts.count == 2,
              let minutes = Int(parts[0]), let seconds = Int(parts[1]),
              minutes >= 0, (0..<60).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
