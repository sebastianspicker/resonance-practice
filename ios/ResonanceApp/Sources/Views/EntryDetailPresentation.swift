import SwiftUI
import UniformTypeIdentifiers

// Presents entry-detail navigation chrome, confirmations, importers, and modal editors.

struct EntryDetailPresentationSurface<Content: View>: View {
  let entry: LocalPracticeEntry
  @Binding var showsSubmitConfirmation: Bool
  @Binding var showsDeleteConfirmation: Bool
  @Binding var showsVideoImporter: Bool
  @Binding var showsCameraCapture: Bool
  @Binding var showsEditGoal: Bool
  @Binding var editGoalText: String
  let refreshFeedback: () async -> Void
  let cleanupPlayback: () -> Void
  let submitEntry: () -> Void
  let deleteEntry: () -> Void
  let attachLessonVideo: (Result<[URL], Error>) async -> Void
  let finishLessonCapture: (TeachingLessonCaptureResult) -> Void
  let saveGoal: (String) -> Void
  let content: Content

  var body: some View {
    content
      .navigationTitle(entry.kind == .teachingLesson ? "Teaching Lesson" : "Practice Entry")
      .navigationBarTitleDisplayMode(.inline)
      .task {
        if ScreenshotScenario.current == nil {
          await refreshFeedback()
        }
      }
      .onDisappear(perform: cleanupPlayback)
      .alert("Submit entry?", isPresented: $showsSubmitConfirmation) {
        Button("Cancel", role: .cancel) {}
        Button("Submit", action: submitEntry)
      } message: {
        Text("Once submitted, the entry cannot be edited. Your teacher will be able to review it.")
      }
      .alert("Delete entry?", isPresented: $showsDeleteConfirmation) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive, action: deleteEntry)
      } message: {
        Text("This removes the entry and queued uploads. This action cannot be undone.")
      }
      .fileImporter(
        isPresented: $showsVideoImporter,
        allowedContentTypes: [.movie],
        allowsMultipleSelection: false
      ) { result in
        Task { @MainActor in
          await attachLessonVideo(result)
        }
      }
      .sheet(isPresented: $showsCameraCapture) {
        TeachingLessonCameraView(
          entryId: entry.id,
          initialProfile: entry.captureProfile,
          onComplete: finishLessonCapture
        )
      }
      .sheet(isPresented: $showsEditGoal) {
        EntryGoalEditor(
          goalText: $editGoalText,
          cancel: { showsEditGoal = false },
          save: saveEditedGoal
        )
      }
  }

  private func saveEditedGoal() {
    saveGoal(editGoalText)
    showsEditGoal = false
  }
}

struct EntryGoalEditor: View {
  @Binding var goalText: String
  let cancel: () -> Void
  let save: () -> Void

  private var canSave: Bool {
    !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Practice goal") {
          TextField("Goal", text: $goalText, axis: .vertical)
            .lineLimit(3...8)
            .accessibilityLabel("Practice goal")
        }
      }
      .navigationTitle("Edit goal")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: cancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save)
            .disabled(!canSave)
        }
      }
    }
    .presentationDetents([.medium])
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
      )
      .font(.headline)
      .foregroundStyle(.orange)
      Text(
        "Reload the server copy to discard this device’s queued changes, or duplicate this draft to keep them as a new entry."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      HStack {
        Button("Reload server copy", action: reloadServerCopy).buttonStyle(.bordered)
        Button("Duplicate new draft", action: duplicateAsNewDraft).buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .groupedSection()
  }
}
