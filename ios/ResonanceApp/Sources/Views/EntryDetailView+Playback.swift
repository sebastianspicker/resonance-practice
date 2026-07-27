import SwiftUI

// Manages artifact playback state and presentation helpers for an entry detail screen.

extension EntryDetailView {
  func formatTime(_ seconds: TimeInterval) -> String {
    String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
  }

  func isPlaying(_ artifact: LocalArtifact) -> Bool {
    player.isPlaying && playingArtifactID == artifact.id
  }

  func playbackButtonTitle(for artifact: LocalArtifact) -> String {
    if isPlaying(artifact) { return "Stop" }
    if playbackLoadingArtifactID == artifact.id { return "Loading…" }
    return "Play"
  }

  func togglePlayback(for artifact: LocalArtifact) {
    if isPlaying(artifact) {
      playbackTask?.cancel()
      player.stop()
      playingArtifactID = nil
      return
    }
    beginPlayback(for: artifact)
  }

  func beginPlayback(for artifact: LocalArtifact) {
    playbackTask?.cancel()
    player.stop()
    playingArtifactID = nil
    playbackTask = Task { await startPlayback(for: artifact) }
  }

  func startPlayback(for artifact: LocalArtifact) async {
    let artifactID = artifact.id
    playbackLoadingArtifactID = artifactID
    playbackErrorArtifactID = nil
    playbackErrorMessage = nil
    defer { if playbackLoadingArtifactID == artifactID { playbackLoadingArtifactID = nil } }
    do {
      let sourceURL = try await ArtifactPlaybackSourceResolver(apiClient: appState.apiClient)
        .resolve(artifact: artifact, accessToken: authManager.session?.accessToken)
      guard !Task.isCancelled else { return }
      guard player.play(url: sourceURL) else {
        setPlaybackError(
          player.playbackError ?? "Playback could not be started.", artifactID: artifactID)
        return
      }
      playingArtifactID = artifactID
    } catch {
      guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
      setPlaybackError(error.localizedDescription, artifactID: artifactID)
    }
  }

  func setPlaybackError(_ message: String, artifactID: String) {
    playbackErrorArtifactID = artifactID
    playbackErrorMessage = message
  }

  func playbackError(for artifact: LocalArtifact) -> String? {
    if playbackErrorArtifactID == artifact.id { return playbackErrorMessage }
    return playingArtifactID == artifact.id ? player.playbackError : nil
  }

  func captureMarkers(for artifact: LocalArtifact) -> [LocalCaptureMarker] {
    entry.captureMarkers.filter { $0.artifactId == artifact.id }.sorted {
      $0.timeSeconds == $1.timeSeconds
        ? $0.createdAt < $1.createdAt : $0.timeSeconds < $1.timeSeconds
    }
  }

  func statusLabel(_ status: EntryStatus) -> String {
    status.displayLabel
  }

  func statusColor(_ status: EntryStatus) -> Color {
    status.lifecycleStatus.foreground
  }

  func feedbackStatusLabel(_ status: FeedbackStatus) -> String {
    status.displayLabel
  }

  func feedbackStatusColor(_ status: FeedbackStatus) -> Color {
    status.tint
  }
}
