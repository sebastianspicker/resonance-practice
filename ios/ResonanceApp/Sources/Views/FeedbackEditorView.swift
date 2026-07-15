import AVFoundation
import SwiftUI

struct MarkerDraft: Identifiable, Equatable {
    let id = UUID()
    var time: String
    var text: String
}

struct FeedbackEditorView: View {
    let entry: ReviewQueueEntry
    var playbackTime: () -> TimeInterval = { 0 }
    var onQueued: (() -> Void)?

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var syncManager: SyncManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var status: FeedbackStatus = .ok
    @State private var commentsText = ""
    @State private var markers: [MarkerDraft] = []
    @State private var isSending = false
    @State private var validationMessage: String?
    @State private var confirmDiscard = false

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
                    Text("Goal met").tag(FeedbackStatus.ok)
                    Text("Revise").tag(FeedbackStatus.needsRevision)
                    Text("Next goal").tag(FeedbackStatus.nextGoal)
                }
                .pickerStyle(.menu)
                Text(statusHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                TextField("Comments", text: $commentsText, axis: .vertical)
                    .lineLimit(4...10)
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Validation error: \(validationMessage)")
                }
            }

            Section("Timestamped markers") {
                ForEach($markers) { $marker in
                    VStack(alignment: .leading) {
                        TextField("Time (mm:ss)", text: $marker.time)
                            .textContentType(.none)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("Marker note", text: $marker.text, axis: .vertical)
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
                Button(isSending ? "Queueing…" : "Queue feedback") {
                    queueFeedback()
                }
                .disabled(commentsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .confirmationDialog("Discard unsent feedback?", isPresented: $confirmDiscard) {
            Button("Discard feedback", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your comments and markers have not been queued.")
        }
    }

    private var hasDraft: Bool { !commentsText.isEmpty || !markers.isEmpty }

    private var statusHint: String {
        switch status {
        case .ok: return "The submitted goal was met."
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
                "feedbackId": feedbackId,
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
