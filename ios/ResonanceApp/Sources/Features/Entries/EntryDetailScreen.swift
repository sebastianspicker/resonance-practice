import SwiftData
import SwiftUI

struct EntryDetailScreen: View {
  @Bindable var entry: LocalPracticeEntry
  @Environment(\.dismiss) var dismiss
  @Environment(\.modelContext) var modelContext
  @Environment(\.scenePhase) var scenePhase
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var syncManager: SyncManager
  @EnvironmentObject var authManager: AuthManager
  @EnvironmentObject var networkMonitor: NetworkMonitor
  @StateObject var recorder = AudioRecorder()
  @StateObject var player = AudioPlayer()
  @State var isLoadingFeedback = false
  @State var feedbackRequestID: UUID?
  @State var hasMoreFeedback = false
  @State var feedbackCursor: String?
  @State var feedbackLoadGeneration = 0
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
  @State var practiceStage: PracticeEntryStage
  @State var reflectionText: String
  @State var reflectionError: String?
  @State var practiceError: String?
  @State var didStartGuidedRecording = false
  @State var isPracticeVisible = false
  @State var isRequestingMicrophone = false
  @State var showRecordingExitConfirmation = false
  @State var showRetakeConfirmation = false
  @State var showsSyncQueue = false
  @FocusState var reflectionFocused: Bool
  @Query var submissionItems: [SyncQueueItem]
  @Query var entryCourses: [LocalCourse]
  let showsArtifacts: Bool
  let startsWithRecording: Bool
  let onFinish: (() -> Void)?

  init(
    entry: LocalPracticeEntry, initialSection: String?, showsArtifacts: Bool,
    onFinish: (() -> Void)? = nil
  ) {
    self.entry = entry
    self.showsArtifacts = showsArtifacts
    _scrollTarget = State(initialValue: initialSection)
    self.onFinish = onFinish
    startsWithRecording = initialSection == "guided-record"
    _reflectionText = State(initialValue: entry.notes ?? "")
    _practiceStage = State(initialValue: PracticeEntryStage.initial(for: entry, section: initialSection))
    let ownerID = entry.studentId
    let courseID = entry.courseId
    _submissionItems = Query(filter: #Predicate<SyncQueueItem> {
      $0.ownerId == ownerID && $0.type == "submitEntry"
    })
    _entryCourses = Query(filter: #Predicate<LocalCourse> { $0.id == courseID })
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
      usesGuidedPractice: usesGuidedPractice,
      content: detailContent
    )
  }

  @ViewBuilder private var detailContent: some View {
    if usesGuidedPractice {
      guidedPracticeContent
    } else {
      entryContent
    }
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
      hasMoreFeedback: hasMoreFeedback, loadMoreFeedback: loadMoreFeedback,
      confirmConsent: confirmPrivateCourseReviewConsent,
      hasAudio: entry.artifacts.contains { $0.type == .audio },
      retake: retakeLastLocalAudio, editGoal: editGoal
    )
  }

  private func requestSubmit() { showSubmitConfirmation = true }
  private func requestDelete() { showDeleteConfirmation = true }
  func editGoal() { editGoalText = entry.goalText; showEditGoal = true }
  private func cleanupPlayback() {
    playbackTask?.cancel()
    player.stop()
    if recorder.isRecording { stopRecording() }
  }
}
