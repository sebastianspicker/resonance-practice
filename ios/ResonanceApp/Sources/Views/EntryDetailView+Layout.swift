import SwiftUI

// Composes reusable layout sections for entry metadata, status, and recording information.

struct EntryDetailContent: View {
  let entry: LocalPracticeEntry
  let recorder: AudioRecorder
  let player: AudioPlayer
  let showsArtifacts: Bool
  let isConflicted: Bool
  let isLoadingFeedback: Bool
  let playingArtifactID: String?
  let playbackLoadingArtifactID: String?
  let playbackError: (LocalArtifact) -> String?
  let feedbackStatusLabel: (FeedbackStatus) -> String
  let feedbackStatusColor: (FeedbackStatus) -> Color
  let formatTime: (TimeInterval) -> String
  let isPlaying: (LocalArtifact) -> Bool
  let playbackTitle: (LocalArtifact) -> String
  let captureMarkers: (LocalArtifact) -> [LocalCaptureMarker]
  let startRecording: () -> Void
  let stopRecording: () -> Void
  let togglePlayback: (LocalArtifact) -> Void
  let beginPlayback: (LocalArtifact) -> Void
  let reloadServerCopy: () -> Void
  let duplicateAsNewDraft: () -> Void
  let submit: () -> Void
  let delete: () -> Void
  @Binding var showVideoImporter: Bool
  @Binding var showCameraCapture: Bool
  let captureProfileSelection: Binding<CaptureProfile>
  let draftInstruction: String
  var isOnline: Bool = true
  var pendingSyncCount: Int = 0
  var confirmConsent: (() -> Void)? = nil
  var hasAudio: Bool = false
  var retake: (() -> Void)? = nil
  var editGoal: (() -> Void)? = nil

  var body: some View {
    ZStack {
      AppTheme.Background()
      ScrollView {
        VStack(spacing: 24) {
          if !isOnline {
            OfflineHonestyBanner(pendingCount: pendingSyncCount)
          }
          EntryStatusSection(entry: entry)
          if isConflicted {
            EntryConflictRecoverySection(
              reloadServerCopy: reloadServerCopy, duplicateAsNewDraft: duplicateAsNewDraft)
          }
          EntryGoalSection(entry: entry)
          EntryRecordingSection(
            entry: entry,
            recorder: recorder,
            captureProfileSelection: captureProfileSelection,
            startRecording: startRecording,
            stopRecording: stopRecording,
            showVideoImporter: $showVideoImporter,
            showCameraCapture: $showCameraCapture,
            confirmConsent: confirmConsent
          )
          if showsArtifacts {
            EntryArtifactsSection(
              entry: entry, player: player, playingArtifactID: playingArtifactID,
              playbackLoadingArtifactID: playbackLoadingArtifactID, playbackError: playbackError,
              formatTime: formatTime, isPlaying: isPlaying, playbackTitle: playbackTitle,
              captureMarkers: captureMarkers, togglePlayback: togglePlayback,
              beginPlayback: beginPlayback)
          }
          EntryFeedbackSection(
            entry: entry, isLoading: isLoadingFeedback, feedbackStatusLabel: feedbackStatusLabel,
            feedbackStatusColor: feedbackStatusColor, formatTime: formatTime)
          EntryActionsSection(
            entry: entry,
            draftInstruction: draftInstruction,
            submit: submit,
            delete: delete,
            hasAudio: hasAudio,
            retake: retake,
            editGoal: editGoal
          )
        }.padding()
      }
    }
  }
}

struct EntryStatusSection: View {
  let entry: LocalPracticeEntry
  var body: some View {
    HStack {
      Text("Entry status").font(.headline)
      Spacer()
      StatusPill(
        status: entry.status.studentLifecycle(isRemoteBacked: entry.remoteUpdatedAt != nil)
      )
    }
    .groupedSection()
  }
}

struct EntryGoalSection: View {
  let entry: LocalPracticeEntry
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      WorkspaceSectionLabel(title: "Practice goal")
      Text(entry.goalText).font(.title3.weight(.medium))
      if let notes = entry.notes { Text(notes).foregroundStyle(AppTheme.workspaceMuted) }
    }
    .frame(maxWidth: .infinity, alignment: .leading).groupedSection()
  }
}

struct EntryRecordingSection: View {
  let entry: LocalPracticeEntry
  let recorder: AudioRecorder
  let captureProfileSelection: Binding<CaptureProfile>
  let startRecording: () -> Void
  let stopRecording: () -> Void
  @Binding var showVideoImporter: Bool
  @Binding var showCameraCapture: Bool
  var confirmConsent: (() -> Void)? = nil

  private var hasConsent: Bool {
    entry.consentConfirmedAt != nil && entry.consentScope != nil
  }

  private var isTeachingLesson: Bool {
    entry.kind == .teachingLesson
  }

  private var isDraft: Bool {
    entry.status == .draft
  }

  var body: some View {
    // Capture controls only apply to drafts; submitted/reviewed evidence lives in the list below.
    if isDraft {
      VStack(alignment: .leading, spacing: 12) {
        WorkspaceSectionLabel(title: "Evidence")

        if isTeachingLesson {
          teachingLessonCaptureControls
        } else {
          // Practice audio only — hide for teaching lessons (video is primary).
          practiceAudioControls
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .groupedSection()
    }
  }

  @ViewBuilder private var practiceAudioControls: some View {
    if recorder.isRecording {
      LiveRecordingStage(
        duration: recorder.duration,
        averageLevel: recorder.averageLevel,
        isRecording: true
      )
      Button("Stop recording", action: stopRecording)
        .buttonStyle(.bordered)
        .accessibilityLabel("Stop recording")
        .accessibilityHint("Stops the current audio recording and attaches it to this entry")
    } else {
      Button("Record audio", action: startRecording)
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Record audio")
        .accessibilityHint("Starts recording practice audio for this draft")
    }
  }

  @ViewBuilder private var teachingLessonCaptureControls: some View {
    consentChip

    Picker("Capture profile", selection: captureProfileSelection) {
      ForEach(CaptureProfile.allCases) { Text($0.label).tag($0) }
    }
    .pickerStyle(.menu)
    .accessibilityLabel("Capture profile")
    .accessibilityHint("Selects the camera perspective for this teaching lesson")

    HStack {
      Button("Film lesson") { showCameraCapture = true }
        .buttonStyle(.borderedProminent)
        .disabled(!hasConsent)
        .accessibilityLabel("Film lesson")
        .accessibilityHint(
          hasConsent
            ? "Opens the camera to film a teaching lesson"
            : "Confirm private course review before filming"
        )

      Button("Import video") { showVideoImporter = true }
        .buttonStyle(.bordered)
        .disabled(!hasConsent)
        .accessibilityLabel("Import video")
        .accessibilityHint(
          hasConsent
            ? "Imports a lesson video from Files"
            : "Confirm private course review before importing"
        )
    }

    if !hasConsent {
      Text("Confirm private course review to film or import.")
        .font(.caption)
        .foregroundStyle(AppTheme.workspaceMuted)
        .accessibilityLabel("Confirm private course review to film or import")
    }
  }

  @ViewBuilder private var consentChip: some View {
    if hasConsent {
      HStack(spacing: 6) {
        Circle()
          .fill(Color.white)
          .frame(width: 6, height: 6)
        Text("Private course review")
          .font(.caption.weight(.semibold))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(AppTheme.accent.opacity(0.92), in: Capsule(style: .continuous))
      .foregroundStyle(Color.white)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Private course review consent")
      .accessibilityValue("Confirmed")
    } else if let confirmConsent {
      Button(action: confirmConsent) {
        HStack(spacing: 6) {
          Circle()
            .fill(AppTheme.accent)
            .frame(width: 6, height: 6)
          Text("Confirm private course review")
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
          Capsule(style: .continuous)
            .strokeBorder(AppTheme.accent.opacity(0.75), lineWidth: 1)
        }
        .foregroundStyle(AppTheme.accent)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Confirm private course review")
      .accessibilityHint("Confirms consent for private course review so you can film or import")
    }
  }
}
