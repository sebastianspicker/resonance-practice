import SwiftUI

struct MarkerDraft: Identifiable {
    let id = UUID()
    var timeSeconds: String
    var text: String
}

struct FeedbackEditorView: View {
    let entry: ReviewQueueEntry
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var status: FeedbackStatus = .ok
    @State private var commentsText: String = ""
    @State private var markers: [MarkerDraft] = []
    @State private var isSending = false
    @State private var markerValidationError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.PremiumBackground()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Entry Section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Entry")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            Text(entry.studentName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            Text(entry.goalText)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()

                        // Status Section
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Status")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)

                            Picker("Status", selection: $status) {
                                Text("OK").tag(FeedbackStatus.ok)
                                Text("Needs Revision").tag(FeedbackStatus.needsRevision)
                                Text("Next Goal").tag(FeedbackStatus.nextGoal)
                            }
                            .pickerStyle(.segmented)
                            .colorScheme(.dark)
                            .accessibilityLabel("Feedback status")
                            .accessibilityHint("Select OK, Needs Revision, or Next Goal")

                            Text(statusHint(status))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                                .transition(.opacity)
                                .animation(.easeInOut(duration: 0.2), value: status)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()

                        // Feedback Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Feedback")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            GlassTextField(placeholder: "Comments", text: $commentsText, axis: .vertical, lineLimit: 4...8)
                                .accessibilityLabel("Feedback comments")
                                .accessibilityHint("Enter your feedback comments for the student")
                        }
                        .glassCard()

                        // Snippets Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Snippets")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(FeedbackSnippet.defaults, id: \.self) { snippet in
                                        Button(snippet) {
                                            if commentsText.isEmpty {
                                                commentsText = snippet
                                            } else {
                                                commentsText += " " + snippet
                                            }
                                        }
                                        .buttonStyle(SubtleGlassButtonStyle())
                                        .accessibilityHint("Appends this text to comments")
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()

                        // Markers Section
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Markers")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            ForEach($markers) { $marker in
                                HStack {
                                    GlassTextField(placeholder: "Time (s)", text: $marker.timeSeconds, keyboardType: .numberPad, cornerRadius: 8, width: 80)
                                        .accessibilityLabel("Marker time in seconds")

                                    GlassTextField(placeholder: "Note", text: $marker.text, cornerRadius: 8)
                                        .accessibilityLabel("Marker note")
                                }
                            }
                            Button("Add Marker") {
                                markers.append(MarkerDraft(timeSeconds: "", text: ""))
                            }
                            .buttonStyle(SubtleGlassButtonStyle())
                            .accessibilityLabel("Add marker")
                            .accessibilityHint("Double-tap to add a new time marker to this feedback")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
                }
                .safeAreaPadding(.horizontal, 8)
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await sendFeedback() } }
                        .disabled(commentsText.isEmpty || isSending)
                        .foregroundStyle(commentsText.isEmpty || isSending ? .white.opacity(0.5) : .white)
                        .accessibilityLabel("Send feedback")
                        .accessibilityHint(commentsText.isEmpty ? "Enter comments first" : "Double-tap to submit this feedback to the student")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                        .accessibilityLabel("Cancel")
                        .accessibilityHint("Double-tap to discard feedback and go back")
                }
            }
            .alert("Invalid Markers", isPresented: .init(
                get: { markerValidationError != nil },
                set: { if !$0 { markerValidationError = nil } }
            )) {
                Button("OK") { markerValidationError = nil }
            } message: {
                Text(markerValidationError ?? "")
            }
        }
    }

    private func statusHint(_ status: FeedbackStatus) -> String {
        switch status {
        case .ok:
            return "The student met expectations for this entry."
        case .needsRevision:
            return "Ask the student to re-practice and resubmit."
        case .nextGoal:
            return "Good progress -- suggest the next practice goal."
        }
    }

    private func sendFeedback() async {
        guard !isSending, let session = authManager.session else { return }

        // Validate markers: reject incomplete or invalid entries instead of
        // silently dropping them, which could cause the teacher to lose work.
        let nonEmptyMarkers = markers.filter { !$0.timeSeconds.isEmpty || !$0.text.isEmpty }
        for marker in nonEmptyMarkers {
            if marker.timeSeconds.isEmpty {
                markerValidationError = "Each marker needs a time value."
                return
            }
            guard let seconds = Int(marker.timeSeconds), seconds >= 0 else {
                markerValidationError = "Marker time must be a non-negative number."
                return
            }
            if marker.text.isEmpty {
                markerValidationError = "Each marker needs a note."
                return
            }
        }

        isSending = true
        defer { isSending = false }

        let feedbackId = UUID().uuidString
        let markerModels = nonEmptyMarkers.map { draft in
            // Force-unwrap is safe: validation above guarantees Int conversion succeeds.
            LocalMarker(id: UUID().uuidString, timeSeconds: Int(draft.timeSeconds)!, text: draft.text)
        }

        let localFeedback = LocalFeedback(id: feedbackId, targetType: "entry", targetId: entry.id, teacherName: "", status: status, commentsText: commentsText)
        for marker in markerModels {
            modelContext.insert(marker)
            localFeedback.markers.append(marker)
        }
        modelContext.insert(localFeedback)
        do {
            try modelContext.save()
        } catch {
            appState.reportError(error)
            return
        }

        syncManager.enqueue(type: .postFeedback, payload: [
            "targetType": "entry",
            "targetId": entry.id,
            "feedbackId": feedbackId
        ])
        dismiss()
    }
}

private enum FeedbackSnippet {
    static let defaults: [String] = [
        "Strong musical phrasing.",
        "Great rhythm stability.",
        "Please slow down and clean articulation.",
        "Watch intonation in longer notes.",
        "Excellent progress since last submission."
    ]
}
