import SwiftUI

struct PracticeRecordingMeter: View {
  @ObservedObject var recorder: AudioRecorder
  @ScaledMetric(relativeTo: .largeTitle) private var timerSize = 76

  var body: some View {
    VStack(spacing: 22) {
      Text(time(recorder.isRecording ? recorder.duration : 0))
        .font(.system(size: timerSize, weight: .regular, design: .serif))
        .monospacedDigit()
        .minimumScaleFactor(0.5)
        .lineLimit(1)
        .accessibilityLabel("Recording time")
        .accessibilityValue(time(recorder.isRecording ? recorder.duration : 0))
      HStack(alignment: .center, spacing: 6) {
        ForEach(0..<17) { index in
          Capsule()
            .fill(recorder.isRecording ? PracticeFlowTheme.recording : PracticeFlowTheme.border)
            .frame(width: 5, height: meterHeight(index))
        }
      }
      .frame(height: 56)
      .accessibilityHidden(true)
      Label {
        Text(recorder.isRecording ? "Recording audio" : "Ready to record")
          .foregroundStyle(PracticeFlowTheme.ink)
      } icon: {
        Image(systemName: "circle.fill")
          .foregroundStyle(recorder.isRecording ? PracticeFlowTheme.recording : PracticeFlowTheme.secondary)
      }
      .font(.subheadline)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 30)
    .padding(.horizontal, 16)
    .background(PracticeFlowTheme.audioSurface, in: RoundedRectangle(cornerRadius: 18))
  }

  private func meterHeight(_ index: Int) -> CGFloat {
    let contour = 0.3 + 0.7 * abs(sin(Double(index + 1) * 1.7))
    return recorder.isRecording ? 5 + 50 * recorder.averageLevel * contour : 5
  }

  private func time(_ seconds: TimeInterval) -> String {
    String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
  }
}

struct PracticeAudioPlayback: View {
  let artifact: LocalArtifact
  @ObservedObject var player: AudioPlayer
  let isCurrent: Bool
  let isLoading: Bool
  let error: String?
  let toggle: () -> Void

  private var duration: Double {
    isCurrent && player.duration > 0 ? player.duration : Double(artifact.durationSeconds)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 14) {
        Button(action: toggle) {
          Image(systemName: isCurrent && player.isPlaying ? "stop.fill" : "play.fill")
            .font(.title3)
            .frame(width: 48, height: 48)
            .foregroundStyle(PracticeFlowTheme.accentInk)
            .background(PracticeFlowTheme.accent, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(isCurrent && player.isPlaying ? "Stop practice audio" : "Play practice audio")
        .accessibilityIdentifier("practice.play.\(artifact.id)")
        VStack(alignment: .leading, spacing: 4) {
          Text("Practice audio · \(time(duration))").font(.subheadline)
          Text("\(time(isCurrent ? player.currentTime : 0)) / \(time(duration))")
            .font(.caption).monospacedDigit().foregroundStyle(PracticeFlowTheme.secondary)
          Slider(
            value: Binding(get: { isCurrent ? min(player.currentTime, max(duration, 1)) : 0 },
                           set: { player.seek(to: $0) }),
            in: 0...max(duration, 1)
          )
          .disabled(!isCurrent || isLoading)
          .accessibilityLabel("Recording position")
          .accessibilityValue(time(isCurrent ? player.currentTime : 0))
          .accessibilityHint("Play the recording to enable seeking")
        }
      }
      if isLoading { ProgressView("Preparing secure playback…").font(.caption) }
      if let error {
        Text(error).font(.footnote).foregroundStyle(AppTheme.statusFailedForeground)
        Button("Try playback again", action: toggle).font(.subheadline)
      }
      Text(artifact.syncPhase.lifecycleStatus.label)
        .font(.caption).foregroundStyle(PracticeFlowTheme.secondary)
    }
    .padding(16)
    .background(PracticeFlowTheme.audioSurface, in: RoundedRectangle(cornerRadius: 16))
  }

  private func time(_ seconds: TimeInterval) -> String {
    String(format: "%02d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
  }
}

extension EntryDetailView {
  var practiceAudio: some View {
    VStack(spacing: 12) {
      ForEach(entry.artifacts.sorted { $0.createdAt < $1.createdAt }) { artifact in
        if artifact.type == .audio {
          PracticeAudioPlayback(
            artifact: artifact, player: player, isCurrent: playingArtifactID == artifact.id,
            isLoading: playbackLoadingArtifactID == artifact.id, error: playbackError(for: artifact),
            toggle: { togglePlayback(for: artifact) })
        } else {
          Label("Video attached · \(formatTime(TimeInterval(artifact.durationSeconds)))", systemImage: "video")
        }
      }
      if entry.artifacts.isEmpty {
        Text("Record a passage before submitting.")
          .font(.subheadline).foregroundStyle(PracticeFlowTheme.secondary)
      }
    }
  }

  var practiceReceipt: some View {
    VStack(alignment: .leading, spacing: 24) {
      PracticeFlowTitle(deliveryState.title)
      VStack(spacing: 12) {
        Image(systemName: receiptSymbol)
          .font(.system(size: 56, weight: .light))
          .foregroundStyle(deliveryState.isConfirmed ? PracticeFlowTheme.accent : PracticeFlowTheme.warning)
          .accessibilityHidden(true)
        Text(deliveryState.label).font(.headline)
          .accessibilityIdentifier("practice.delivery-state")
      }
      .frame(maxWidth: .infinity).padding(.vertical, 8)
      Divider()
      practiceGoal
      practiceAudio
      VStack(alignment: .leading, spacing: 16) {
        if deliveryState.isConfirmed {
          receiptRow("Recording uploaded", complete: true)
          receiptRow("Submission confirmed", complete: true)
          receiptRow("Available to teachers in \(practiceCourseTitle)", complete: true)
        } else {
          receiptRow("Entry saved on this device", complete: true)
          receiptRow(recordingDeliveryLabel, complete: allRecordingsUploaded)
          receiptRow(pendingDeliveryLabel, complete: false)
        }
      }
      .font(.subheadline)
      Divider()
      Text(deliveryExplanation).font(.subheadline).foregroundStyle(PracticeFlowTheme.secondary)
      VStack(spacing: 12) {
        if deliveryState.isConfirmed {
          Button("View entry") { practiceStage = .details }
            .buttonStyle(PracticeFlowButtonStyle())
            .accessibilityIdentifier("practice.view-entry")
        } else if deliveryState == .failed || deliveryState == .sending {
          Button("Open sync status") { showsSyncQueue = true }
            .buttonStyle(PracticeFlowButtonStyle())
        } else if deliveryState == .unqueued {
          Button("Review submission") { practiceStage = .check }
            .buttonStyle(PracticeFlowButtonStyle())
        }
        Button("Back to entries", action: finishPractice)
          .buttonStyle(PracticeFlowButtonStyle(primary: !deliveryState.isConfirmed && deliveryState == .queued))
      }
    }
  }

  var practiceDetails: some View {
    VStack(alignment: .leading, spacing: 24) {
      PracticeFlowTitle(entry.status == .reviewed ? "Your teacher’s feedback." : "Your practice entry.")
      Text(entry.status.displayLabel).font(.headline)
      practiceGoal
      practiceAudio
      if let notes = entry.notes { Text(notes) }
      practiceMetadata
      EntryFeedbackSection(
        entry: entry, isLoading: isLoadingFeedback, feedbackStatusLabel: feedbackStatusLabel,
        feedbackStatusColor: feedbackStatusColor, formatTime: formatTime,
        hasMoreFeedback: hasMoreFeedback, loadMoreFeedback: loadMoreFeedback)
      Button("Back to entries", action: finishPractice).buttonStyle(PracticeFlowButtonStyle())
    }
  }

  private var allRecordingsUploaded: Bool {
    !entry.artifacts.isEmpty && entry.artifacts.allSatisfy { $0.uploadState == .uploaded }
  }

  private var receiptSymbol: String {
    if deliveryState.isConfirmed { return "checkmark.circle" }
    return deliveryState == .failed || deliveryState == .unqueued ? "exclamationmark.circle" : "clock"
  }

  private var recordingDeliveryLabel: String {
    if allRecordingsUploaded { return "Recording uploaded" }
    if entry.artifacts.contains(where: { $0.syncPhase == .confirming }) { return "Checking recording" }
    return networkMonitor.isOnline ? "Recording upload pending" : "Recording saved on this device"
  }

  private var pendingDeliveryLabel: String {
    switch deliveryState {
    case .failed: "Open sync status to resolve the problem"
    case .unqueued: "Submission was not queued"
    case .queued: "Waiting for a connection"
    default: "Waiting for submission confirmation"
    }
  }

  private var deliveryExplanation: String {
    if deliveryState.isConfirmed { return "Feedback appears on this entry after review." }
    if deliveryState == .queued {
      return "Your teachers cannot see this entry yet. Open Resonance when you are online to finish sending."
    }
    return "Your teachers cannot see this entry yet. Your draft stays private until submission is confirmed."
  }

  private func receiptRow(_ title: String, complete: Bool) -> some View {
    Label(title, systemImage: complete ? "checkmark.circle.fill" : "clock")
      .foregroundStyle(complete ? PracticeFlowTheme.accent : PracticeFlowTheme.secondary)
  }
}
