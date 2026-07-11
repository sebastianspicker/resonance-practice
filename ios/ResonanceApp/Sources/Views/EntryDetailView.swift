import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

struct EntryDetailView: View {
    @Bindable var entry: LocalPracticeEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var player = AudioPlayer()
    @State private var isLoadingFeedback = false
    @State private var showDeleteConfirmation = false
    @State private var showSubmitConfirmation = false
    @State private var showVideoImporter = false
    @State private var showCameraCapture = false

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

                        if entry.kind == .teachingLesson && entry.status == .draft {
                            Picker("Capture profile", selection: captureProfileSelection) {
                                ForEach(CaptureProfile.allCases) { profile in
                                    Text(profile.label).tag(profile)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.white)
                            .accessibilityLabel("Teaching lesson capture profile")

                            HStack(spacing: 12) {
                                Button(action: { showCameraCapture = true }) {
                                    HStack {
                                        Image(systemName: "video.fill")
                                        Text("Film Lesson")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(VibrantGlassButtonStyle())
                                .accessibilityLabel("Film lesson")

                                Button(action: { showVideoImporter = true }) {
                                    HStack {
                                        Image(systemName: "square.and.arrow.down")
                                        Text("Import Video")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(SubtleGlassButtonStyle())
                                .accessibilityLabel("Import lesson video")
                            }
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
                                        if artifact.type == .audio {
                                            Button(isPlaying(artifact) ? "Stop" : "Play") {
                                                if isPlaying(artifact) {
                                                    player.stop()
                                                } else {
                                                    player.play(url: URL(fileURLWithPath: artifact.localPath))
                                                }
                                            }
                                            .buttonStyle(SubtleGlassButtonStyle())
                                            .accessibilityLabel(isPlaying(artifact) ? "Stop playback" : "Play \(artifact.type.rawValue) recording")
                                            .accessibilityHint(isPlaying(artifact) ? "Double-tap to stop playback" : "Double-tap to play this recording")
                                        } else {
                                            VStack(alignment: .trailing, spacing: 4) {
                                                Text("Attached")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.white.opacity(0.7))
                                                if !captureMarkers(for: artifact).isEmpty {
                                                    Text("\(captureMarkers(for: artifact).count) lesson markers")
                                                        .font(.caption2)
                                                        .foregroundStyle(AppTheme.accentVibrant)
                                                }
                                            }
                                        }
                                    }

                                    // Mini player with seek
                                    if isPlaying(artifact) && player.duration > 0 {
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

                                    if artifact.type == .video {
                                        let lessonMarkers = captureMarkers(for: artifact)
                                        if !lessonMarkers.isEmpty {
                                            VStack(alignment: .leading, spacing: 6) {
                                                ForEach(lessonMarkers) { marker in
                                                    HStack(alignment: .top, spacing: 8) {
                                                        Text(formatTime(TimeInterval(marker.timeSeconds)))
                                                            .font(.caption.monospacedDigit().weight(.semibold))
                                                            .foregroundStyle(AppTheme.accentVibrant)
                                                            .frame(width: 44, alignment: .trailing)
                                                        Text(marker.kind.label)
                                                            .font(.caption)
                                                            .foregroundStyle(.white.opacity(0.8))
                                                    }
                                                    .accessibilityElement(children: .combine)
                                                    .accessibilityLabel("Lesson marker at \(marker.timeSeconds) seconds: \(marker.kind.label)")
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.top, 4)
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
                            Text(draftInstruction)
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
        .navigationTitle(entry.kind == .teachingLesson ? "Teaching Lesson" : "Practice Entry")
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
        .fileImporter(
            isPresented: $showVideoImporter,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false,
            onCompletion: attachLessonVideo
        )
        .sheet(isPresented: $showCameraCapture) {
            TeachingLessonCameraView(
                entryId: entry.id,
                initialProfile: entry.captureProfile,
                onComplete: finishLessonCapture
            )
        }
    }

    private var captureProfileSelection: Binding<CaptureProfile> {
        Binding(
            get: { entry.captureProfile ?? .teacherLearner },
            set: { updateCaptureProfile($0) }
        )
    }

    private var draftInstruction: String {
        if entry.kind == .teachingLesson {
            return "Film or import a lesson video, then submit for course review."
        }
        return "Record audio above, then submit for your teacher to review."
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
        guard let url = recorder.lastURL else {
            appState.reportError(NSError(domain: "Resonance", code: 0, userInfo: [NSLocalizedDescriptionKey: "Recording file is unavailable."]))
            return
        }
        guard recorder.duration > 0, FileManager.default.fileExists(atPath: url.path) else {
            FileStore.deleteFileIfExists(atPath: url.path)
            appState.reportError(NSError(domain: "Resonance", code: 0, userInfo: [NSLocalizedDescriptionKey: "Recording did not complete, so no audio was attached."]))
            return
        }
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

    private func updateCaptureProfile(_ profile: CaptureProfile) {
        guard entry.captureProfile != profile else { return }
        entry.captureProfile = profile
        do {
            try modelContext.save()
        } catch {
            appState.reportError(error)
            return
        }
        syncManager.enqueue(type: .syncCaptureProfile, payload: ["entryId": entry.id])
    }

    @discardableResult
    private func ensureTeachingLessonCaptureProfile() -> Bool {
        guard entry.kind == .teachingLesson, entry.captureProfile == nil else {
            return false
        }
        entry.captureProfile = .teacherLearner
        return true
    }

    private func attachLessonVideo(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let destination = FileStore.createVideoFileURL(
                entryId: entry.id,
                fileExtension: sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
            )
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            FileStore.setFileProtection(url: destination)

            let artifact = LocalArtifact(
                id: UUID().uuidString,
                entryId: entry.id,
                type: .video,
                durationSeconds: videoDurationSeconds(url: destination),
                localPath: destination.path
            )
            let didSetDefaultProfile = ensureTeachingLessonCaptureProfile()
            entry.artifacts.append(artifact)
            modelContext.insert(artifact)
            try modelContext.save()
            if didSetDefaultProfile {
                syncManager.enqueue(type: .syncCaptureProfile, payload: ["entryId": entry.id])
            }
        } catch {
            appState.reportError(error)
        }
    }

    private func finishLessonCapture(_ result: TeachingLessonCaptureResult) {
        let artifact = LocalArtifact(
            id: UUID().uuidString,
            entryId: entry.id,
            type: .video,
            durationSeconds: result.durationSeconds,
            localPath: result.videoURL.path
        )
        entry.captureProfile = result.captureProfile
        entry.artifacts.append(artifact)
        modelContext.insert(artifact)

        for markerDraft in result.markers {
            let marker = LocalCaptureMarker(
                id: markerDraft.id,
                entryId: entry.id,
                artifactId: artifact.id,
                timeSeconds: markerDraft.timeSeconds,
                kind: markerDraft.kind,
                note: markerDraft.note
            )
            entry.captureMarkers.append(marker)
            modelContext.insert(marker)
        }

        do {
            try modelContext.save()
        } catch {
            appState.reportError(error)
            return
        }

        syncManager.enqueue(type: .syncCaptureProfile, payload: ["entryId": entry.id])
    }

    private func videoDurationSeconds(url: URL) -> Int {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite && seconds > 0 {
            return Int(seconds.rounded())
        }
        return 0
    }

    private func submitEntry() {
        guard !entry.artifacts.isEmpty else {
            reportSubmissionError("At least one recording is required before submitting.")
            return
        }
        guard prepareTeachingLessonSubmission() else { return }
        if let artifactError = submissionArtifactError() {
            reportSubmissionError(artifactError)
            return
        }
        do {
            try modelContext.save()
        } catch {
            appState.reportError(error)
            return
        }
        syncManager.enqueue(type: .submitEntry, payload: ["entryId": entry.id])
    }

    private func prepareTeachingLessonSubmission() -> Bool {
        guard entry.kind == .teachingLesson else { return true }
        guard entry.consentConfirmedAt != nil, entry.consentScope != nil else {
            reportSubmissionError("Confirm consent before submitting this teaching lesson.")
            return false
        }
        let videos = entry.artifacts.filter { $0.type == .video }
        guard !videos.isEmpty else {
            reportSubmissionError("Film or import a lesson video before submitting this teaching lesson.")
            return false
        }
        let didSetDefaultProfile = ensureTeachingLessonCaptureProfile()
        enqueueTeachingLessonMetadata(didSetDefaultProfile: didSetDefaultProfile)
        let localVideos = videos.filter { $0.uploadState == .pending }
        guard !localVideos.isEmpty else { return true }
        for artifact in localVideos {
            artifact.uploadState = .uploading
            artifact.syncPhase = .queued
            syncManager.enqueue(type: .syncArtifact, payload: ["artifactId": artifact.id])
        }
        do {
            try modelContext.save()
        } catch {
            appState.reportError(error)
            return false
        }
        reportSubmissionError("Lesson video upload queued. Submit again after sync finishes.")
        return false
    }

    private func enqueueTeachingLessonMetadata(didSetDefaultProfile: Bool) {
        if didSetDefaultProfile || entry.captureProfile != nil {
            syncManager.enqueue(type: .syncCaptureProfile, payload: ["entryId": entry.id])
        }
        if !entry.captureMarkers.isEmpty {
            syncManager.enqueue(type: .syncCaptureMarkers, payload: ["entryId": entry.id])
        }
    }

    private func submissionArtifactError() -> String? {
        if entry.artifacts.contains(where: { $0.uploadState == .failed }) {
            return "Some recordings failed to sync. Retry them before submitting."
        }
        if entry.artifacts.contains(where: { $0.uploadState != .uploaded }) {
            return "All artifacts must be uploaded before submitting."
        }
        return nil
    }

    private func reportSubmissionError(_ message: String) {
        appState.reportError(NSError(domain: "Resonance", code: 0, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private func deleteEntry() {
        player.stop()
        if recorder.isRecording {
            recorder.stopRecording()
            if let lastURL = recorder.lastURL {
                FileStore.deleteFileIfExists(atPath: lastURL.path)
            }
        }

        do {
            _ = try EntryDeletionCoordinator.delete(entry: entry, modelContext: modelContext) { type, payload in
                syncManager.enqueue(type: type, payload: payload)
            }
            dismiss()
        } catch {
            appState.reportError(error)
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

    private func isPlaying(_ artifact: LocalArtifact) -> Bool {
        player.isPlaying && player.currentFilePath == artifact.localPath
    }

    private func captureMarkers(for artifact: LocalArtifact) -> [LocalCaptureMarker] {
        entry.captureMarkers
            .filter { $0.artifactId == artifact.id }
            .sorted {
                if $0.timeSeconds == $1.timeSeconds {
                    return $0.createdAt < $1.createdAt
                }
                return $0.timeSeconds < $1.timeSeconds
            }
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
