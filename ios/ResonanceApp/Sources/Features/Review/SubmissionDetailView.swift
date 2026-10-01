import AVKit
import SwiftUI

// Sheet/detail presentation for a single queue entry with evidence + feedback.

@MainActor
struct SecureReviewArtifactLoadState {
    let isLoading: Binding<Bool>
    let playbackError: Binding<String?>
    let beforeLoad: () -> Void
}

@MainActor
func loadSecureReviewArtifact(
    _ artifact: ArtifactResponse?,
    accessToken: String?,
    appState: AppState,
    player: AVPlayer,
    state: SecureReviewArtifactLoadState
) async {
    guard let artifact, let accessToken else { return }
    state.isLoading.wrappedValue = true
    state.playbackError.wrappedValue = nil
    player.pause()
    state.beforeLoad()
    defer { state.isLoading.wrappedValue = false }
    do {
        let response = try await appState.apiClient.fetchArtifactDownloadURL(
            accessToken: accessToken,
            artifactId: artifact.id
        )
        player.replaceCurrentItem(with: AVPlayerItem(url: response.downloadUrl))
    } catch {
        player.replaceCurrentItem(with: nil)
        state.playbackError.wrappedValue = error.localizedDescription
    }
}

struct SubmissionDetailView: View {
    let entry: ReviewQueueEntry
    let onFeedbackQueued: () -> Void
    private let loadsRemoteMedia: Bool
    private let isFeedbackQueued: Bool
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthManager
    @State private var selectedArtifactId: String?
    @State private var player = AVPlayer()
    @State private var playbackError: String?
    @State private var isLoadingMedia = false

    init(
        entry: ReviewQueueEntry,
        onFeedbackQueued: @escaping () -> Void,
        loadsRemoteMedia: Bool = true,
        isFeedbackQueued: Bool = false
    ) {
        self.entry = entry
        self.onFeedbackQueued = onFeedbackQueued
        self.loadsRemoteMedia = loadsRemoteMedia
        self.isFeedbackQueued = isFeedbackQueued
    }

    var body: some View {
        NavigationStack {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    evidencePane.frame(minWidth: 360)
                    Divider()
                    feedbackPane.frame(minWidth: 360)
                }
                ScrollView {
                    VStack(spacing: 16) {
                        evidencePane
                        feedbackPane
                    }
                }
            }
            .navigationTitle(entry.studentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    StatusPill(status: isFeedbackQueued ? .feedbackQueued : .submitted)
                }
            }
            .task {
                selectedArtifactId = entry.artifacts.first?.id
                if loadsRemoteMedia { await loadSelectedArtifact() }
            }
            .onChange(of: selectedArtifactId) { _, _ in
                if loadsRemoteMedia { Task { await loadSelectedArtifact() } }
            }
            .onDisappear { player.pause() }
        }
    }

    private var evidencePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.goalText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.workspaceInk)
            if let notes = entry.notes, !notes.isEmpty {
                Text(notes).foregroundStyle(.secondary)
            }
            if entry.artifacts.isEmpty {
                ContentUnavailableView("No playable evidence", systemImage: "waveform.slash")
            } else {
                Picker("Evidence", selection: $selectedArtifactId) {
                    ForEach(entry.artifacts) { artifact in
                        Text(artifact.type == "video" ? "Video" : "Audio")
                            .tag(Optional(artifact.id))
                    }
                }
                .pickerStyle(.segmented)

                MediaStageCard(title: mediaStageTitle) {
                    VStack(alignment: .leading, spacing: 12) {
                        VideoPlayer(player: player)
                            .frame(minHeight: 240)
                            .background(
                                Color.black,
                                in: RoundedRectangle(cornerRadius: AppTheme.Radius.stage, style: .continuous)
                            )
                            .accessibilityLabel("Submitted evidence player")
                        if isLoadingMedia {
                            ProgressView("Preparing secure playback…")
                        }
                        if !loadsRemoteMedia {
                            Label("Authorized course media ready", systemImage: "lock.shield")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let playbackError {
                            ContentUnavailableView {
                                Label("Playback unavailable", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(playbackError)
                            } actions: {
                                Button("Try again") { Task { await loadSelectedArtifact() } }
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Label(
                        entry.practiceDate.formatted(date: .abbreviated, time: .omitted),
                        systemImage: "calendar"
                    )
                    Label(
                        TeacherQueueView.totalDurationLabel(for: entry),
                        systemImage: "clock"
                    )
                    Label(
                        entry.artifacts.count == 1
                            ? "1 artifact"
                            : "\(entry.artifacts.count) artifacts",
                        systemImage: "waveform"
                    )
                }
                .font(.caption)
                .foregroundStyle(AppTheme.workspaceMuted)
            }
        }
        .padding()
    }

    private var mediaStageTitle: String {
        let type = entry.artifacts.first(where: { $0.id == selectedArtifactId })?.type
        return type == "video" ? "Evidence · video" : "Evidence · audio"
    }

    private var feedbackPane: some View {
        FeedbackEditorView(
            entry: entry,
            playbackTime: { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 },
            onQueued: onFeedbackQueued
        )
    }

    private func loadSelectedArtifact() async {
        await loadSecureReviewArtifact(
            entry.artifacts.first(where: { $0.id == selectedArtifactId }),
            accessToken: authManager.session?.accessToken,
            appState: appState,
            player: player,
            state: SecureReviewArtifactLoadState(
                isLoading: $isLoadingMedia,
                playbackError: $playbackError,
                beforeLoad: {}
            )
        )
    }
}
