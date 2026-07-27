import SwiftUI

// Defines the entry-detail evidence, feedback, and action sections shared by the detail layout.

struct EntryArtifactsSection: View {
  let entry: LocalPracticeEntry
  let player: AudioPlayer
  let playingArtifactID: String?
  let playbackLoadingArtifactID: String?
  let playbackError: (LocalArtifact) -> String?
  let formatTime: (TimeInterval) -> String
  let isPlaying: (LocalArtifact) -> Bool
  let playbackTitle: (LocalArtifact) -> String
  let captureMarkers: (LocalArtifact) -> [LocalCaptureMarker]
  let togglePlayback: (LocalArtifact) -> Void
  let beginPlayback: (LocalArtifact) -> Void

  var body: some View {
    if !entry.artifacts.isEmpty {
      VStack(alignment: .leading, spacing: 16) {
        WorkspaceSectionLabel(title: "Evidence")
        ForEach(entry.artifacts) { artifact in
          VStack(alignment: .leading, spacing: 10) {
            if artifact.type == .audio {
              audioStage(for: artifact)
            } else {
              videoStage(for: artifact)
            }

            if playbackLoadingArtifactID == artifact.id {
              ProgressView("Preparing secure playback…")
            }
            if let error = playbackError(artifact) {
              HStack {
                Text(error).font(.caption).foregroundStyle(AppTheme.statusFailedForeground)
                Spacer()
                Button("Try again") { beginPlayback(artifact) }.font(.caption)
              }
            }
          }
          if artifact.id != entry.artifacts.last?.id { Divider() }
        }
      }.frame(maxWidth: .infinity, alignment: .leading).groupedSection()
    }
  }

  @ViewBuilder private func audioStage(for artifact: LocalArtifact) -> some View {
    if isPlaying(artifact) {
      LivePlaybackStage(
        currentTime: player.currentTime,
        duration: player.duration > 0 ? player.duration : TimeInterval(artifact.durationSeconds),
        isPlaying: true,
        averageLevel: player.averageLevel,
        onSeek: { player.seek(to: $0) },
        title: "Evidence · audio",
        status: artifact.syncPhase.lifecycleStatus
      )
    } else {
      MediaStageCard(title: "Evidence · audio", status: artifact.syncPhase.lifecycleStatus) {
        WaveformStageView(
          progress: 0,
          isActive: false,
          liveLevel: nil,
          currentTimeLabel: "0:00",
          durationLabel: formatTime(TimeInterval(artifact.durationSeconds)),
          accessibilitySummary: "Audio waveform, ready to play"
        )
      }
    }

    Button(playbackTitle(artifact)) { togglePlayback(artifact) }
      .buttonStyle(.bordered)
      .disabled(playbackLoadingArtifactID == artifact.id)
      .accessibilityLabel(playbackTitle(artifact) + " audio")
      .accessibilityHint(
        isPlaying(artifact)
          ? "Stops playback of this recording"
          : "Plays this recording"
      )
  }

  @ViewBuilder private func videoStage(for artifact: LocalArtifact) -> some View {
    HStack {
      Text("Video attached")
        .font(.headline)
      Spacer()
      StatusPill(status: artifact.syncPhase.lifecycleStatus)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Video attached, \(artifact.syncPhase.lifecycleStatus.label)")

    let markers = captureMarkers(artifact)
    if !markers.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(markers) { marker in
          Label(
            "\(formatTime(TimeInterval(marker.timeSeconds)))  \(marker.kind.label)",
            systemImage: "flag"
          )
          .font(.caption)
          .foregroundStyle(AppTheme.workspaceMuted)
        }
      }
    }
  }
}

struct EntryFeedbackSection: View {
  let entry: LocalPracticeEntry
  let isLoading: Bool
  let feedbackStatusLabel: (FeedbackStatus) -> String
  let feedbackStatusColor: (FeedbackStatus) -> Color
  let formatTime: (TimeInterval) -> String
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      WorkspaceSectionLabel(title: "Feedback")
      if isLoading {
        ProgressView().frame(maxWidth: .infinity)
      } else if entry.feedback.isEmpty {
        Text(
          entry.status == .draft
            ? "Submit your entry so your teacher can review it." : "No feedback yet"
        ).foregroundStyle(AppTheme.workspaceMuted)
      } else {
        ForEach(entry.feedback) { feedback in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(feedback.teacherName).font(.headline)
              Spacer()
              Text(feedbackStatusLabel(feedback.status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(feedbackStatusColor(feedback.status))
            }
            Text(feedback.commentsText)
            ForEach(feedback.markers) { marker in
              Text("\(formatTime(TimeInterval(marker.timeSeconds)))  \(marker.text)").font(.caption)
                .foregroundStyle(AppTheme.workspaceMuted)
            }
          }
          .padding()
          .background(
            AppTheme.workspaceRaised,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.section, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.section, style: .continuous)
              .stroke(AppTheme.workspaceBorder)
          )
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading).groupedSection().id("feedback")
  }
}

struct EntryActionsSection: View {
  let entry: LocalPracticeEntry
  let draftInstruction: String
  let submit: () -> Void
  let delete: () -> Void
  var hasAudio: Bool = false
  var retake: (() -> Void)? = nil
  var editGoal: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 16) {
      if entry.status == .draft {
        Text(draftInstruction).font(.caption).foregroundStyle(AppTheme.workspaceMuted)
          .multilineTextAlignment(.center)

        HStack(spacing: 12) {
          if let editGoal {
            Button("Edit goal", action: editGoal)
              .buttonStyle(.bordered)
              .accessibilityLabel("Edit goal")
              .accessibilityHint("Opens a sheet to edit the practice goal")
          }
          if hasAudio, let retake {
            Button("Retake", action: retake)
              .buttonStyle(.bordered)
              .accessibilityLabel("Retake audio")
              .accessibilityHint("Removes the last local audio recording and starts a new one")
          }
        }

        Button("Submit to course", action: submit)
          .buttonStyle(.borderedProminent)
          .frame(maxWidth: .infinity)
          .accessibilityLabel("Submit to course")
          .accessibilityHint("Submits this draft for teacher review")
      } else {
        Button("Submit to course", action: submit)
          .buttonStyle(.borderedProminent)
          .disabled(true)
          .opacity(0.5)
          .frame(maxWidth: .infinity)

        Text(
          entry.status == .submitted
            ? "Waiting for teacher feedback." : "Your teacher has reviewed this entry."
        ).font(.caption).foregroundStyle(AppTheme.workspaceMuted)
      }

      Button("Delete entry", action: delete)
        .buttonStyle(.bordered)
        .foregroundStyle(AppTheme.statusFailedForeground)
        .accessibilityLabel("Delete entry")
        .accessibilityHint("Permanently deletes this entry and queued uploads")
    }.padding(.top, 16).padding(.bottom, 40)
  }
}
