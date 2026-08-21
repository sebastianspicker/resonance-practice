import SwiftData
import SwiftUI

// Owns feedback draft state, marker validation, durable queueing, and discard confirmation.

struct MarkerDraft: Identifiable, Equatable {
    let id = UUID()
    var time: String
    var text: String
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

struct FeedbackEditorScreen: View {
    @EnvironmentObject private var appState: AppState
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
        playbackTime: @escaping () -> TimeInterval,
        onQueued: (() -> Void)?,
        initialContent: ScreenshotFeedbackContent?,
        presentation: FeedbackEditorPresentation
    ) {
        self.entry = entry
        self.playbackTime = playbackTime
        self.onQueued = onQueued
        self.presentation = presentation
        _status = State(initialValue: initialContent?.status ?? .accepted)
        _commentsText = State(initialValue: initialContent?.commentsText ?? "")
        _markers = State(initialValue: initialContent?.markers ?? [])
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
        markers.append(MarkerDraft(time: Self.format(playbackTime()), text: ""))
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

extension FeedbackEditorView {
    static func parse(_ value: String) -> Int? { FeedbackEditorScreen.parse(value) }
    static func format(_ interval: TimeInterval) -> String { FeedbackEditorScreen.format(interval) }
}
