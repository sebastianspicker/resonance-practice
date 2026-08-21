import SwiftData
import SwiftUI

// Owns entry detail state, playback cleanup, capture, submission, and conflict recovery.

struct EntryDetailScreen: View {
  @Bindable var entry: LocalPracticeEntry
  @Environment(\.dismiss) var dismiss
  @Environment(\.modelContext) var modelContext
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var syncManager: SyncManager
  @EnvironmentObject var authManager: AuthManager
  @EnvironmentObject var networkMonitor: NetworkMonitor
  @StateObject var recorder = AudioRecorder()
  @StateObject var player = AudioPlayer()
  @State var isLoadingFeedback = false
  @State var showDeleteConfirmation = false
  @State var showSubmitConfirmation = false
  @State var showVideoImporter = false
  @State var showCameraCapture = false
  @State var showEditGoal = false
  @State var editGoalText = ""
  @State var playingArtifactID: String?
  @State var playbackLoadingArtifactID: String?
  @State var playbackErrorArtifactID: String?
  @State var playbackErrorMessage: String?
  @State var playbackTask: Task<Void, Never>?
  @State var scrollTarget: String?
  let showsArtifacts: Bool

  init(entry: LocalPracticeEntry, initialSection: String?, showsArtifacts: Bool) {
    self.entry = entry
    self.showsArtifacts = showsArtifacts
    _scrollTarget = State(initialValue: initialSection)
  }

  var body: some View {
    EntryDetailPresentationSurface(
      entry: entry,
      showsSubmitConfirmation: $showSubmitConfirmation,
      showsDeleteConfirmation: $showDeleteConfirmation,
      showsVideoImporter: $showVideoImporter,
      showsCameraCapture: $showCameraCapture,
      showsEditGoal: $showEditGoal,
      editGoalText: $editGoalText,
      refreshFeedback: refreshFeedback,
      cleanupPlayback: cleanupPlayback,
      submitEntry: submitEntry,
      deleteEntry: deleteEntry,
      attachLessonVideo: attachLessonVideo,
      finishLessonCapture: finishLessonCapture,
      saveGoal: updateGoalText,
      content: entryContent
    )
  }

  private var entryContent: EntryDetailContent {
    EntryDetailContent(
      entry: entry, recorder: recorder, player: player, showsArtifacts: showsArtifacts,
      isConflicted: syncManager.conflictedEntryIDs.contains(entry.id),
      isLoadingFeedback: isLoadingFeedback, playingArtifactID: playingArtifactID,
      playbackLoadingArtifactID: playbackLoadingArtifactID, playbackError: playbackError,
      feedbackStatusLabel: feedbackStatusLabel, feedbackStatusColor: feedbackStatusColor,
      formatTime: formatTime, isPlaying: isPlaying, playbackTitle: playbackButtonTitle,
      captureMarkers: captureMarkers, startRecording: startRecording, stopRecording: stopRecording,
      togglePlayback: togglePlayback, beginPlayback: beginPlayback,
      reloadServerCopy: reloadServerCopy, duplicateAsNewDraft: duplicateAsNewDraft,
      submit: requestSubmit, delete: requestDelete,
      showVideoImporter: $showVideoImporter, showCameraCapture: $showCameraCapture,
      captureProfileSelection: captureProfileSelection, draftInstruction: draftInstruction,
      isOnline: networkMonitor.isOnline, pendingSyncCount: syncManager.pendingQueueCount,
      confirmConsent: confirmPrivateCourseReviewConsent,
      hasAudio: entry.artifacts.contains { $0.type == .audio },
      retake: retakeLastLocalAudio, editGoal: editGoal
    )
  }

  private func requestSubmit() { showSubmitConfirmation = true }
  private func requestDelete() { showDeleteConfirmation = true }
  private func editGoal() { editGoalText = entry.goalText; showEditGoal = true }
  private func cleanupPlayback() { playbackTask?.cancel(); player.stop() }
}
