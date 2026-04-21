import SwiftUI
import SwiftData

struct EntryDetailView: View {
    @Bindable var entry: LocalPracticeEntry
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var player = AudioPlayer()
    @State private var isLoadingFeedback = false
    @State private var showDeleteConfirmation = false
    @State private var showSubmitConfirmation = false

    var body: some View {
        ZStack {
            AppTheme.PremiumBackground()

            ScrollView {
                VStack(spacing: 24) {
                    // Status
                    HStack {
                        Text("Entry status")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(statusLabel(entry.status))
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(statusColor(entry.status).opacity(0.2))
                            .foregroundStyle(statusColor(entry.status))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(statusColor(entry.status).opacity(0.5), lineWidth: 1))
                            .accessibilityLabel("Status: \(statusLabel(entry.status))")
                    }
                    .glassCard()

                    // Goal
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Goal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .textCase(.uppercase)
                        Text(entry.goalText)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white)
                        if let notes = entry.notes {
                            Text(notes)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()

                    // Recording
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recording")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .textCase(.uppercase)

                        if recorder.isRecording {
                            HStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 12, height: 12)
                                    .scaleEffect(recorder.isRecording ? 1.2 : 1.0)
                                    .animation(.easeInOut(duration: 0.8).repeatForever(), value: recorder.isRecording)
                                Text("Recording… \(recorder.duration, specifier: "%.1f")s")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Recording in progress, \(Int(recorder.duration)) seconds")
                            .padding(.bottom, 8)
                        }

                        if recorder.isRecording {
                            Button(action: stopRecording) {
                                HStack {
                                    Image(systemName: "stop.fill")
                                    Text("Stop Recording")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SubtleGlassButtonStyle())
                            .accessibilityLabel("Stop recording")
                            .accessibilityHint("Double-tap to stop the current audio recording")
                        } else {
                            Button(action: startRecording) {
                                HStack {
                                    Image(systemName: "mic.fill")
                                    Text("Record Audio")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(VibrantGlassButtonStyle())
                            .accessibilityLabel("Start audio recording")
                            .accessibilityHint("Double-tap to begin recording audio")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()

                    // Artifacts
                    if !entry.artifacts.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Artifacts")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)

                            ForEach(entry.artifacts) { artifact in
                                VStack(spacing: 8) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(artifact.type.rawValue.uppercased())
                                                .font(.headline)
                                                .foregroundStyle(.white)
                                            Text(artifact.syncPhase.rawValue.capitalized)
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(0.5))
                                        }
                                        Spacer()
                                        Button(player.isPlaying ? "Stop" : "Play") {
                                            if player.isPlaying {
                                                player.stop()
                                            } else {
                                                player.play(url: URL(fileURLWithPath: artifact.localPath))
                                            }
                                        }
                                        .buttonStyle(SubtleGlassButtonStyle())
                                        .accessibilityLabel(player.isPlaying ? "Stop playback" : "Play \(artifact.type.rawValue) recording")
                                        .accessibilityHint(player.isPlaying ? "Double-tap to stop playback" : "Double-tap to play this recording")
                                    }

                                    // Mini player with seek
                                    if player.isPlaying && player.duration > 0 {
                                        VStack(spacing: 4) {
                                            Slider(
                                                value: Binding(
                                                    get: { player.currentTime },
                                                    set: { player.seek(to: $0) }
                                                ),
                                                in: 0...max(player.duration, 0.01)
                                            )
                                            .tint(.white)
                                            .accessibilityLabel("Seek position")
                                            .accessibilityValue(formatTime(player.currentTime))

                                            HStack {
                                                Text(formatTime(player.currentTime))
                                                    .font(.caption.monospacedDigit())
                                                    .foregroundStyle(.white.opacity(0.6))
                                                Spacer()
                                                Text(formatTime(player.duration))
                                                    .font(.caption.monospacedDigit())
                                                    .foregroundStyle(.white.opacity(0.6))
                                            }
                                        }
                                    }
                                }
                                if artifact.id != entry.artifacts.last?.id {
                                    Divider().background(Color.white.opacity(0.2))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                    }

                    // Feedback
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Feedback")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .textCase(.uppercase)

                        if isLoadingFeedback {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                        } else if entry.feedback.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No feedback yet")
                                    .foregroundStyle(.white.opacity(0.5))
                                if entry.status == .draft {
                                    Text("Submit your entry so your teacher can review it.")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.35))
                                } else if entry.status == .submitted {
                                    Text("Your teacher will review this entry soon.")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(entry.feedback) { feedback in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(feedback.teacherName)
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Text(feedbackStatusLabel(feedback.status))
                                            .font(.caption.weight(.bold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(feedbackStatusColor(feedback.status).opacity(0.15))
                                            .foregroundStyle(feedbackStatusColor(feedback.status))
                                            .clipShape(Capsule())
                                            .overlay(Capsule().stroke(feedbackStatusColor(feedback.status).opacity(0.4), lineWidth: 1))
                                    }
                                    Text(feedback.commentsText)
                                        .font(.body)
                                        .foregroundStyle(.white.opacity(0.9))

                                    if !feedback.markers.isEmpty {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Markers")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.white.opacity(0.5))
                                                .padding(.top, 4)
                                            ForEach(feedback.markers) { marker in
                                                HStack(alignment: .top, spacing: 8) {
                                                    Text(formatTime(TimeInterval(marker.timeSeconds)))
                                                        .font(.caption.monospacedDigit().weight(.semibold))
                                                        .foregroundStyle(AppTheme.accentVibrant)
                                                        .frame(width: 44, alignment: .trailing)
                                                    Text(marker.text)
                                                        .font(.caption)
                                                        .foregroundStyle(.white.opacity(0.8))
                                                }
                                                .accessibilityElement(children: .combine)
                                                .accessibilityLabel("At \(marker.timeSeconds) seconds: \(marker.text)")
                                            }
                                        }
                                    }
                                }
                                .padding()
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Feedback from \(feedback.teacherName): \(feedbackStatusLabel(feedback.status)). \(feedback.commentsText)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()

                    // Actions
                    VStack(spacing: 16) {
                        if entry.status == .draft {
                            Text("Record audio above, then submit for your teacher to review.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }

                        Button("Submit for Review") {
                            showSubmitConfirmation = true
                        }
                        .buttonStyle(VibrantGlassButtonStyle())
                        .disabled(entry.status != .draft)
                        .opacity(entry.status != .draft ? 0.5 : 1.0)
                        .accessibilityLabel("Submit entry for review")
                        .accessibilityHint(entry.status != .draft ? "Entry already submitted" : "Submits this practice entry to your teacher")

                        if entry.status != .draft {
                            Text(entry.status == .submitted ? "Waiting for teacher feedback." : "Your teacher has reviewed this entry.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }

                        Button("Delete Entry") {
                            showDeleteConfirmation = true
                        }
                        .buttonStyle(SubtleGlassButtonStyle())
                        .foregroundStyle(.red)
                        .accessibilityLabel("Delete entry")
                        .accessibilityHint("Double-tap to permanently delete this practice entry")
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
                .padding()
            }
        }
        .navigationTitle("Practice Entry")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshFeedback() }
        .alert("Submit entry?", isPresented: $showSubmitConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Submit") { submitEntry() }
        } message: {
            Text("Once submitted, the entry cannot be edited. Your teacher will be able to review it.")
        }
        .alert("Delete entry?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteEntry() }
        } message: {
            Text("This removes the entry and queued uploads. This action cannot be undone.")
        }
    }


    private func startRecording() {
        let url = FileStore.createAudioFileURL(entryId: entry.id)
        do {
            try recorder.startRecording(to: url)
        } catch {
            appState.reportError(error)
        }
    }

    private func stopRecording() {
        recorder.stopRecording()
        guard let url = recorder.lastURL else { return }
        let artifact = LocalArtifact(id: UUID().uuidString, entryId: entry.id, type: .audio, durationSeconds: Int(recorder.duration), localPath: url.path)
        entry.artifacts.append(artifact)
        modelContext.insert(artifact)
        do {
            try modelContext.save()
        } catch {
            appState.reportError(error)
            return
        }
        syncManager.enqueue(type: .syncArtifact, payload: ["artifactId": artifact.id])
    }

    private func submitEntry() {
        guard !entry.artifacts.isEmpty else {
            appState.reportError(NSError(domain: "Resonance", code: 0, userInfo: [NSLocalizedDescriptionKey: "At least one recording is required before submitting."]))
            return
        }
        let hasUnfinishedArtifacts = entry.artifacts.contains { $0.uploadState != .uploaded }
        if hasUnfinishedArtifacts {
            appState.reportError(NSError(domain: "Resonance", code: 0, userInfo: [NSLocalizedDescriptionKey: "All artifacts must be uploaded before submitting."]))
            return
        }
        entry.status = .submitted
        do {
            try modelContext.save()
        } catch {
            appState.reportError(error)
            return
        }
        syncManager.enqueue(type: .submitEntry, payload: ["entryId": entry.id])
    }

    private func deleteEntry() {
        // Check if there are pending createEntry sync items for this entry.
        // If so, the entry was never synced to the server -- remove those items
        // and skip enqueuing a server-side delete.
        let entryId = entry.id
        let createType = SyncTaskType.createEntry.rawValue
        let pendingValue = SyncStatus.pending.rawValue
        let descriptor = FetchDescriptor<SyncQueueItem>(predicate: #Predicate {
            $0.status == pendingValue && $0.type == createType
        })
        let pendingCreates = (try? modelContext.fetch(descriptor)) ?? []
        let hasUnsyncedCreate = pendingCreates.contains { item in
            guard let data = item.payloadJSON.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (payload["entryId"] as? String) == entryId
        }

        entry.deletedAt = Date()
        do {
            try modelContext.save()
        } catch {
            appState.reportError(error)
            return
        }

        // Remove pending sync items for this entry's artifacts
        let artifactIds = Set(entry.artifacts.map { $0.id })
        if !artifactIds.isEmpty {
            let allPendingDescriptor = FetchDescriptor<SyncQueueItem>(predicate: #Predicate {
                $0.status == pendingValue
            })
            let allPendingItems = (try? modelContext.fetch(allPendingDescriptor)) ?? []
            for item in allPendingItems {
                guard let data = item.payloadJSON.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let artifactId = payload["artifactId"] as? String,
                      artifactIds.contains(artifactId) else { continue }
                modelContext.delete(item)
            }
        }

        if hasUnsyncedCreate {
            // Remove pending create items -- no server-side delete needed
            for item in pendingCreates {
                guard let data = item.payloadJSON.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (payload["entryId"] as? String) == entryId else { continue }
                modelContext.delete(item)
            }
            try? modelContext.save()
        } else {
            syncManager.enqueue(type: .deleteEntry, payload: ["entryId": entryId])
        }
    }

    private func refreshFeedback() async {
        guard let session = authManager.session else { return }
        isLoadingFeedback = true
        defer { isLoadingFeedback = false }
        do {
            let feedbackList = try await appState.apiClient.fetchFeedback(accessToken: session.accessToken, entryId: entry.id)
            // Delete old feedback objects from the store before replacing.
            // Simply removing from the relationship array orphans them in SwiftData
            // because cascade delete only fires when the parent is deleted, not when
            // children are removed from the relationship.
            let oldFeedback = entry.feedback
            entry.feedback.removeAll()
            for old in oldFeedback {
                // Cascade delete rule on LocalFeedback.markers will clean up markers
                // when the feedback is deleted from the context.
                modelContext.delete(old)
            }
            for feedback in feedbackList {
                let local = LocalFeedback(id: feedback.id, targetType: feedback.targetType, targetId: feedback.targetId, teacherName: feedback.teacherName, status: FeedbackStatus(rawValue: feedback.status) ?? .ok, commentsText: feedback.commentsText)
                for marker in feedback.markers {
                    let localMarker = LocalMarker(id: marker.id, timeSeconds: marker.timeSeconds, text: marker.text)
                    modelContext.insert(localMarker)
                    local.markers.append(localMarker)
                }
                entry.feedback.append(local)
                modelContext.insert(local)
            }
            try modelContext.save()
        } catch {
            appState.reportError(error)
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func statusLabel(_ status: EntryStatus) -> String {
        switch status {
        case .draft:
            return "Draft"
        case .submitted:
            return "Submitted"
        case .reviewed:
            return "Reviewed"
        }
    }

    private func statusColor(_ status: EntryStatus) -> Color {
        switch status {
        case .draft:
            return .secondary
        case .submitted:
            return .orange
        case .reviewed:
            return .green
        }
    }

    private func feedbackStatusLabel(_ status: FeedbackStatus) -> String {
        switch status {
        case .ok:
            return "OK"
        case .needsRevision:
            return "Needs Revision"
        case .nextGoal:
            return "Next Goal"
        }
    }

    private func feedbackStatusColor(_ status: FeedbackStatus) -> Color {
        switch status {
        case .ok:
            return .green
        case .needsRevision:
            return .orange
        case .nextGoal:
            return .blue
        }
    }
}
