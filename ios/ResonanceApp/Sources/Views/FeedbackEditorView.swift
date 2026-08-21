import SwiftUI

// Stable navigation entrypoint for structured teacher feedback.

struct FeedbackEditorView: View {
    let entry: ReviewQueueEntry
    let playbackTime: () -> TimeInterval
    let onQueued: (() -> Void)?
    private let initialContent: ScreenshotFeedbackContent?
    private let presentation: FeedbackEditorPresentation

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
        self.initialContent = initialContent
        self.presentation = presentation
    }

    var body: some View {
        FeedbackEditorScreen(
            entry: entry, playbackTime: playbackTime, onQueued: onQueued,
            initialContent: initialContent, presentation: presentation
        )
    }
}
