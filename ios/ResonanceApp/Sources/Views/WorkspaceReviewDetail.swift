import AVKit
import SwiftUI

// Workspace detail: evidence stage + feedback editor for a selected queue entry.

struct WorkspaceReviewDetail: View {
    let entry: ReviewQueueEntry
    let initialFeedbackContent: ScreenshotFeedbackContent?
    let onFeedbackQueued: () -> Void
    var isFeedbackQueued: Bool = false
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthManager
    @State private var selectedArtifactId: String?
    @State private var player = AVPlayer()
    @State private var isLoadingMedia = false
    @State private var playbackError: String?
    /// Drives TimelineView refresh for audio transport (AVPlayer rate is not Observable).
    @State private var isAudioPlaying = false

    private var usesIllustratedPlayback: Bool { ScreenshotScenario.current != nil }

    private var selectedArtifact: ArtifactResponse? {
        entry.artifacts.first { $0.id == selectedArtifactId }
    }

    private var isSelectedAudio: Bool {
        selectedArtifact?.type == "audio"
    }

    private var lifecycleLeading: LifecycleStatus {
        isFeedbackQueued ? .feedbackQueued : .submitted
    }

    private var evidenceTitle: String {
        let type = selectedArtifact?.type == "video" ? "video" : "audio"
        if entry.artifacts.isEmpty {
            return "Evidence"
        }
        if entry.artifacts.count == 1 {
            return "Evidence · \(type)"
        }
        return "Evidence · \(type) · \(entry.artifacts.count) items"
    }

    var body: some View {
        HStack(spacing: 0) {
            evidencePane
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            WorkspaceDivider()
            FeedbackEditorView(
                entry: entry,
                playbackTime: { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 },
                onQueued: onFeedbackQueued,
                initialContent: initialFeedbackContent,
                presentation: .workspace
            )
            .frame(width: 340)
            .frame(maxHeight: .infinity)
        }
        .workspacePanel()
        .task {
            selectedArtifactId = entry.artifacts.first?.id
            if !usesIllustratedPlayback { await loadSelectedArtifact() }
        }
        .onChange(of: selectedArtifactId) { _, _ in
            if !usesIllustratedPlayback { Task { await loadSelectedArtifact() } }
        }
        .onChange(of: entry.id) { _, _ in
            selectedArtifactId = entry.artifacts.first?.id
            if !usesIllustratedPlayback { Task { await loadSelectedArtifact() } }
        }
        .onDisappear { player.pause() }
    }

    private var evidencePane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detailBar
                    if entry.artifacts.isEmpty {
                        ContentUnavailableView("No evidence", systemImage: "waveform.slash")
                    } else {
                        if entry.artifacts.count > 1 {
                            Picker("Evidence", selection: $selectedArtifactId) {
                                ForEach(entry.artifacts) { artifact in
                                    Text(artifact.type == "video" ? "Video" : "Audio")
                                        .tag(Optional(artifact.id))
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityHint("Selects evidence for secure playback")
                        }

                        evidenceStage

                        goalAndMetaCard
                        playbackMarkers
                    }
                }
                .padding(26)
            }
            StatusRail(
                items: ["Private course review"],
                leading: lifecycleLeading
            )
        }
        .background(AppTheme.workspaceBackground)
    }

    @ViewBuilder private var evidenceStage: some View {
        if usesIllustratedPlayback {
            MediaStageCard(title: evidenceTitle, status: lifecycleLeading) {
                WorkspaceWaveformPlayer(duration: selectedArtifact?.durationSeconds ?? 198)
            }
        } else if isSelectedAudio {
            TimelineView(.animation(minimumInterval: 0.1, paused: !isAudioPlaying)) { _ in
                let snapshot = audioSnapshot()
                VStack(alignment: .leading, spacing: 10) {
                    LivePlaybackStage(
                        currentTime: snapshot.currentTime,
                        duration: snapshot.duration,
                        isPlaying: isAudioPlaying,
                        averageLevel: isAudioPlaying ? snapshot.decorativeLevel : nil,
                        onSeek: seekAudio(to:),
                        title: evidenceTitle,
                        status: lifecycleLeading
                    )
                    audioTransport(isPlaying: isAudioPlaying)
                    mediaStatusChrome
                }
            }
        } else {
            MediaStageCard(title: evidenceTitle, status: lifecycleLeading) {
                videoPlayerPane
            }
        }
    }

    private var detailBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(entry.studentName) · \(TeacherQueueView.kindDisplayName(entry.kind))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.workspaceMuted)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text(entry.goalText)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.workspaceInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
        }
    }

    private var goalAndMetaCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceSectionLabel(title: "Submission")
            if let notes = entry.notes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.workspaceInkSoft)
            }
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                metaCell(
                    title: "Date",
                    value: entry.practiceDate.formatted(date: .abbreviated, time: .omitted)
                )
                metaCell(title: "Duration", value: TeacherQueueView.totalDurationLabel(for: entry))
                metaCell(
                    title: "Artifacts",
                    value: entry.artifacts.count == 1
                        ? "1 item"
                        : "\(entry.artifacts.count) items"
                )
                metaCell(title: "Kind", value: TeacherQueueView.kindDisplayName(entry.kind))
            }
        }
        .padding(AppTheme.Spacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.workspacePanel,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.section, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.section, style: .continuous)
                .stroke(AppTheme.workspaceBorder)
        )
    }

    private func metaCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.workspaceMuted)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.workspaceInk)
        }
    }

    private var videoPlayerPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoPlayer(player: player)
                .frame(minHeight: 260)
                .background(
                    Color.black,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.stage, style: .continuous)
                )
                .accessibilityLabel("Authorized course recording")
            mediaStatusChrome
        }
    }

    @ViewBuilder private var mediaStatusChrome: some View {
        if isLoadingMedia {
            ProgressView("Preparing secure playback…")
        }
        if let playbackError {
            Label(playbackError, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(AppTheme.statusFailedForeground)
        }
    }

    private func audioTransport(isPlaying: Bool) -> some View {
        HStack(spacing: 20) {
            Button {
                skip(by: -10)
            } label: {
                Image(systemName: "gobackward.10")
            }
            .accessibilityLabel("Skip back 10 seconds")

            Button {
                togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .padding(14)
                    .background(AppTheme.accent, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .disabled(player.currentItem == nil || isLoadingMedia)

            Button {
                skip(by: 10)
            } label: {
                Image(systemName: "goforward.10")
            }
            .accessibilityLabel("Skip forward 10 seconds")

            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.workspaceInk)
        .padding(.top, 4)
    }

    private var playbackMarkers: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceSectionLabel(title: "Markers")
                .padding(.bottom, 12)
            if usesIllustratedPlayback {
                WorkspaceTimelineRow(time: "00:38", text: "Opening carries well", isAccent: false)
                WorkspaceTimelineRow(time: "01:24", text: "Build the crescendo earlier", isAccent: true)
                WorkspaceTimelineRow(time: "02:47", text: "Let the closing phrase breathe", isAccent: false)
            } else {
                Text("Markers can be added while writing feedback.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.workspaceMuted)
            }
        }
        .padding(.top, 6)
    }

    private struct AudioSnapshot {
        let currentTime: TimeInterval
        let duration: TimeInterval
        let isPlaying: Bool
        let decorativeLevel: Double
    }

    private func audioSnapshot() -> AudioSnapshot {
        let current = player.currentTime().seconds
        let safeCurrent = current.isFinite ? current : 0
        let itemDuration = player.currentItem?.duration.seconds ?? .nan
        let fallback = TimeInterval(selectedArtifact?.durationSeconds ?? 0)
        let duration = (itemDuration.isFinite && itemDuration > 0) ? itemDuration : fallback
        // Remote streams have no metering; soft pulse tracks playback time only.
        let decorative = 0.2 + 0.15 * abs(sin(safeCurrent * 3))
        return AudioSnapshot(
            currentTime: safeCurrent,
            duration: duration,
            isPlaying: isAudioPlaying,
            decorativeLevel: decorative
        )
    }

    private func togglePlayPause() {
        if isAudioPlaying {
            player.pause()
            isAudioPlaying = false
        } else {
            player.play()
            isAudioPlaying = true
        }
    }

    private func skip(by seconds: TimeInterval) {
        let current = player.currentTime().seconds
        let base = current.isFinite ? current : 0
        let itemDuration = player.currentItem?.duration.seconds ?? .nan
        let fallback = TimeInterval(selectedArtifact?.durationSeconds ?? 0)
        let duration = (itemDuration.isFinite && itemDuration > 0) ? itemDuration : fallback
        let target = max(0, min(base + seconds, max(duration, 0.01)))
        seekAudio(to: target)
    }

    private func seekAudio(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600))
    }

    private func loadSelectedArtifact() async {
        guard let selectedArtifact,
              let token = authManager.session?.accessToken else { return }
        isLoadingMedia = true
        playbackError = nil
        player.pause()
        isAudioPlaying = false
        defer { isLoadingMedia = false }
        do {
            let response = try await appState.apiClient.fetchArtifactDownloadURL(
                accessToken: token,
                artifactId: selectedArtifact.id
            )
            player.replaceCurrentItem(with: AVPlayerItem(url: response.downloadUrl))
        } catch {
            player.replaceCurrentItem(with: nil)
            playbackError = error.localizedDescription
        }
    }
}
