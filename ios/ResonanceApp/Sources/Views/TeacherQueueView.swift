import AVKit
import SwiftUI

extension ReviewQueueEntry: Identifiable {}
extension ArtifactResponse: Identifiable {}

struct TeacherQueueView: View {
    let courseId: String
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthManager
    @State private var queue: [ReviewQueueEntry] = []
    @State private var selected: ReviewQueueEntry?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var queuedFeedback = Set<String>()

    var body: some View {
        Group {
            if isLoading && queue.isEmpty {
                ProgressView("Loading submissions…")
            } else if queue.isEmpty {
                ContentUnavailableView(
                    "Nothing to review",
                    systemImage: "checkmark.circle",
                    description: Text("New submissions will appear here.")
                )
            } else {
                List(queue) { entry in
                    Button { selected = entry } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.studentName).font(.headline)
                                Spacer()
                                if queuedFeedback.contains(entry.id) {
                                    Label("Feedback queued", systemImage: "clock")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(entry.goalText).foregroundStyle(.primary).lineLimit(2)
                            Text("\(entry.artifacts.count) evidence items · \(entry.practiceDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the submission and media player")
                }
                .refreshable { await refreshQueue() }
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage {
                HStack {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Retry") { Task { await refreshQueue() } }
                }
                .padding()
                .background(.bar)
            }
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshQueue() } }
                .disabled(isLoading)
        }
        .task { await refreshQueue() }
        .sheet(item: $selected) { entry in
            SubmissionDetailView(entry: entry) {
                queuedFeedback.insert(entry.id)
            }
        }
    }

    private func refreshQueue() async {
        guard let session = authManager.session else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let firstPage = try await appState.apiClient.fetchReviewQueue(
                accessToken: session.accessToken,
                courseId: courseId,
                limit: 50
            )
            queue = firstPage.items
            var cursor = firstPage.nextCursor
            var seen = Set<String>()
            while let next = cursor, seen.insert(next).inserted {
                let page = try await appState.apiClient.fetchReviewQueue(
                    accessToken: session.accessToken,
                    courseId: courseId,
                    limit: 50,
                    cursor: next
                )
                queue.append(contentsOf: page.items)
                cursor = page.nextCursor
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SubmissionDetailView: View {
    let entry: ReviewQueueEntry
    let onFeedbackQueued: () -> Void
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthManager
    @State private var selectedArtifactId: String?
    @State private var player = AVPlayer()
    @State private var playbackError: String?
    @State private var isLoadingMedia = false

    var body: some View {
        NavigationStack {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    evidencePane.frame(minWidth: 360)
                    Divider()
                    feedbackPane.frame(minWidth: 360)
                }
                ScrollView { VStack(spacing: 16) { evidencePane; feedbackPane } }
            }
            .navigationTitle(entry.studentName)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                selectedArtifactId = entry.artifacts.first?.id
                await loadSelectedArtifact()
            }
            .onChange(of: selectedArtifactId) { _, _ in
                Task { await loadSelectedArtifact() }
            }
        }
    }

    private var evidencePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.goalText).font(.title3.weight(.semibold))
            if let notes = entry.notes, !notes.isEmpty { Text(notes).foregroundStyle(.secondary) }
            if entry.artifacts.isEmpty {
                ContentUnavailableView("No playable evidence", systemImage: "waveform.slash")
            } else {
                Picker("Evidence", selection: $selectedArtifactId) {
                    ForEach(entry.artifacts) { artifact in
                        Text(artifact.type == "video" ? "Video" : "Audio").tag(Optional(artifact.id))
                    }
                }
                VideoPlayer(player: player)
                    .frame(minHeight: 240)
                    .accessibilityLabel("Submitted evidence player")
                if isLoadingMedia { ProgressView("Preparing secure playback…") }
                if let playbackError {
                    ContentUnavailableView {
                        Label("Playback unavailable", systemImage: "exclamationmark.triangle")
                    } description: { Text(playbackError) } actions: {
                        Button("Try again") { Task { await loadSelectedArtifact() } }
                    }
                }
            }
        }
        .padding()
    }

    private var feedbackPane: some View {
        FeedbackEditorView(
            entry: entry,
            playbackTime: { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 },
            onQueued: onFeedbackQueued
        )
    }

    private func loadSelectedArtifact() async {
        guard let selectedArtifactId,
              let artifact = entry.artifacts.first(where: { $0.id == selectedArtifactId }),
              let token = authManager.session?.accessToken else { return }
        isLoadingMedia = true
        playbackError = nil
        player.pause()
        defer { isLoadingMedia = false }
        do {
            let response = try await appState.apiClient.fetchArtifactDownloadURL(
                accessToken: token,
                artifactId: artifact.id
            )
            player.replaceCurrentItem(with: AVPlayerItem(url: response.downloadUrl))
        } catch {
            player.replaceCurrentItem(with: nil)
            playbackError = error.localizedDescription
        }
    }
}
