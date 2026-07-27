import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// Hosts the selected entry's details, editing state, playback, and conflict-recovery affordances.

struct EntryDetailView: View {
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

  init(entry: LocalPracticeEntry, initialSection: String? = nil, showsArtifacts: Bool = true) {
    self.entry = entry
    self.showsArtifacts = showsArtifacts
    _scrollTarget = State(initialValue: initialSection)
  }

  var body: some View {
    EntryDetailContent(
      entry: entry, recorder: recorder, player: player, showsArtifacts: showsArtifacts,
      isConflicted: syncManager.conflictedEntryIDs.contains(entry.id),
      isLoadingFeedback: isLoadingFeedback, playingArtifactID: playingArtifactID,
      playbackLoadingArtifactID: playbackLoadingArtifactID, playbackError: playbackError,
      feedbackStatusLabel: feedbackStatusLabel,
      feedbackStatusColor: feedbackStatusColor, formatTime: formatTime, isPlaying: isPlaying,
      playbackTitle: playbackButtonTitle, captureMarkers: captureMarkers,
      startRecording: startRecording, stopRecording: stopRecording, togglePlayback: togglePlayback,
      beginPlayback: beginPlayback, reloadServerCopy: reloadServerCopy,
      duplicateAsNewDraft: duplicateAsNewDraft,
      submit: { showSubmitConfirmation = true }, delete: { showDeleteConfirmation = true },
      showVideoImporter: $showVideoImporter, showCameraCapture: $showCameraCapture,
      captureProfileSelection: captureProfileSelection, draftInstruction: draftInstruction,
      isOnline: networkMonitor.isOnline, pendingSyncCount: syncManager.pendingQueueCount,
      confirmConsent: confirmPrivateCourseReviewConsent,
      hasAudio: entry.artifacts.contains { $0.type == .audio },
      retake: { retakeLastLocalAudio() },
      editGoal: {
        editGoalText = entry.goalText
        showEditGoal = true
      }
    )
    .navigationTitle(entry.kind == .teachingLesson ? "Teaching Lesson" : "Practice Entry")
    .navigationBarTitleDisplayMode(.inline)
    .task { if ScreenshotScenario.current == nil { await refreshFeedback() } }
    .onDisappear {
      playbackTask?.cancel()
      player.stop()
    }
    .alert("Submit entry?", isPresented: $showSubmitConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Submit", action: submitEntry)
    } message: {
      Text("Once submitted, the entry cannot be edited. Your teacher will be able to review it.")
    }
    .alert("Delete entry?", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive, action: deleteEntry)
    } message: {
      Text("This removes the entry and queued uploads. This action cannot be undone.")
    }
    .fileImporter(
      isPresented: $showVideoImporter, allowedContentTypes: [.movie], allowsMultipleSelection: false
    ) { result in Task { @MainActor in await attachLessonVideo(result) } }
    .sheet(isPresented: $showCameraCapture) {
      TeachingLessonCameraView(
        entryId: entry.id, initialProfile: entry.captureProfile, onComplete: finishLessonCapture)
    }
    .sheet(isPresented: $showEditGoal) {
      NavigationStack {
        Form {
          Section("Practice goal") {
            TextField("Goal", text: $editGoalText, axis: .vertical)
              .lineLimit(3...8)
              .accessibilityLabel("Practice goal")
          }
        }
        .navigationTitle("Edit goal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { showEditGoal = false }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              updateGoalText(editGoalText)
              showEditGoal = false
            }
            .disabled(editGoalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
      .presentationDetents([.medium])
    }
  }
}

struct EntryConflictRecoverySection: View {
  let reloadServerCopy: () -> Void
  let duplicateAsNewDraft: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(
        "This entry changed on another device.",
        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
      ).font(.headline).foregroundStyle(.orange)
      Text(
        "Reload the server copy to discard this device’s queued changes, or duplicate this draft to keep them as a new entry."
      ).font(.subheadline).foregroundStyle(.secondary)
      HStack {
        Button("Reload server copy", action: reloadServerCopy).buttonStyle(.bordered)
        Button("Duplicate new draft", action: duplicateAsNewDraft).buttonStyle(.borderedProminent)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).groupedSection()
  }
}
