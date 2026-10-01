import SwiftData
import SwiftUI

// Edits structured teacher feedback and queues it for durable sync.

/// Initial editor content supplied by the presenting context.
struct FeedbackPrefill: Equatable {
    let status: FeedbackStatus
    let commentsText: String
    let markers: [MarkerDraft]
}

enum FeedbackEditorPresentation: Equatable {
    case form
    case workspace
}

private struct DiscardFeedbackConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let dismiss: DismissAction

    func body(content: Content) -> some View {
        content.confirmationDialog("Discard unsent feedback?", isPresented: $isPresented) {
            Button("Discard feedback", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your comments and markers have not been queued.")
        }
    }
}

struct FeedbackEditorView: View {
    @EnvironmentObject private var errorReporter: ErrorReporter
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var syncManager: SyncManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let entry: ReviewQueueEntry
    let playbackTime: () -> TimeInterval
    let onQueued: (() -> Void)?
    private let presentation: FeedbackEditorPresentation
    @State private var status: FeedbackStatus = .accepted
    @State private var commentsText = ""
    @State private var markers: [MarkerDraft] = []
    @State private var isSending = false
    @State private var validationMessage: String?
    @State private var confirmDiscard = false

    init(
        entry: ReviewQueueEntry,
        playbackTime: @escaping () -> TimeInterval = { 0 },
        onQueued: (() -> Void)? = nil,
        prefill: FeedbackPrefill? = nil,
        presentation: FeedbackEditorPresentation = .form
    ) {
        self.entry = entry
        self.playbackTime = playbackTime
        self.onQueued = onQueued
        self.presentation = presentation
        _status = State(initialValue: prefill?.status ?? .accepted)
        _commentsText = State(initialValue: prefill?.commentsText ?? "")
        _markers = State(initialValue: prefill?.markers ?? [])
    }

    var body: some View {
        FeedbackEditorSurface(
            presentation: presentation, entry: entry, status: $status,
            commentsText: $commentsText, markers: $markers, isSending: isSending,
            validationMessage: $validationMessage, statusHint: statusHint,
            addMarker: addMarker, removeMarker: removeMarker, cancel: cancel, send: queueFeedback
        )
        .modifier(DiscardFeedbackConfirmation(isPresented: $confirmDiscard, dismiss: dismiss))
    }

    private var hasDraft: Bool { !commentsText.isEmpty || !markers.isEmpty }

    private var statusHint: String {
        switch status {
        case .accepted: return "The submitted goal was met."
        case .needsRevision: return "Ask the student to revise this work."
        case .nextGoal: return "Set a concrete next practice goal."
        }
    }

    private func addMarker() {
        markers.append(MarkerDraft(time: MarkerDraft.formatTime(playbackTime()), text: ""))
    }

    private func removeMarker(_ markerID: UUID) {
        markers.removeAll { $0.id == markerID }
    }

    private func cancel() {
        if hasDraft { confirmDiscard = true } else { dismiss() }
    }

    private func queueFeedback() {
        guard !isSending, let session = authManager.session else { return }
        validationMessage = nil
        let operation = FeedbackDraftQueueOperation(
            entry: entry, teacherName: session.displayName, status: status,
            commentsText: commentsText, markers: markers
        )
        do {
            try operation.validate()
        } catch let error as FeedbackDraftValidationError {
            validationMessage = error.errorDescription
            return
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        isSending = true
        do {
            try operation.persist(in: modelContext, syncManager: syncManager)
            onQueued?()
            dismiss()
        } catch {
            isSending = false
            errorReporter.report(error)
        }
    }
}
