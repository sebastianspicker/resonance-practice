import AVFoundation
import SwiftUI

extension EntryDetailView {
  var usesGuidedPractice: Bool {
    entry.kind == .practice && authManager.session?.userId == entry.studentId
  }

  var queuedSubmissions: [SyncQueueItem] {
    submissionItems.filter {
      PracticeDeliveryState.belongsToEntry($0, entryID: entry.id, ownerID: entry.studentId)
    }
  }

  var deliveryState: PracticeDeliveryState {
    PracticeDeliveryState.resolve(
      status: entry.status, hasSubmission: !queuedSubmissions.isEmpty,
      hasFailure: queuedSubmissions.contains { $0.queueStatus == .failed }
        || entry.artifacts.contains { $0.uploadState == .failed },
      isOnline: networkMonitor.isOnline)
  }

  var canEditPractice: Bool { entry.status == .draft && queuedSubmissions.isEmpty }
  var practiceCourseTitle: String { entryCourses.first?.title ?? "Your course" }
  var isPracticeReceipt: Bool {
    practiceStage == .receipt || (!queuedSubmissions.isEmpty && practiceStage != .details)
  }

  var guidedPracticeContent: some View {
    PracticeFlowPage(scrollResetID: "\(practiceStage):\(isPracticeReceipt)") {
      VStack(alignment: .leading, spacing: 28) {
        PracticeFlowHeader(
          courseTitle: practiceCourseTitle,
          step: practiceStage == .record && !isPracticeReceipt ? .record : .review)
        if let practiceError {
          Label(practiceError, systemImage: "exclamationmark.circle")
            .font(.subheadline).foregroundStyle(AppTheme.statusFailedForeground)
            .accessibilityIdentifier("practice.error")
        }
        if syncManager.conflictedEntryIDs.contains(entry.id) {
          EntryConflictRecoverySection(
            reloadServerCopy: reloadServerCopy, duplicateAsNewDraft: duplicateAsNewDraft)
        }
        if isPracticeReceipt {
          practiceReceipt
        } else {
          practiceStageContent
        }
      }
    }
    .tint(PracticeFlowTheme.accent)
    .foregroundStyle(PracticeFlowTheme.ink)
    .navigationBarBackButtonHidden()
    .toolbar { practiceToolbar }
    .interactiveDismissDisabled(recorder.isRecording || reflectionText != (entry.notes ?? ""))
    .task {
      isPracticeVisible = true
      beginGuidedPracticeIfNeeded()
    }
    .task(id: practiceSyncKey) { await continuePracticeSubmission() }
    .onDisappear { isPracticeVisible = false }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active && recorder.isRecording { stopGuidedRecording() }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
      if recorder.isRecording { stopGuidedRecording() }
    }
    .onChange(of: entry.status) { _, status in
      if status != .draft { practiceStage = .receipt }
    }
    .confirmationDialog("Stop and save this recording?", isPresented: $showRecordingExitConfirmation) {
      Button("Stop and save") { stopGuidedRecording() }
      Button("Keep recording", role: .cancel) {}
    }
    .confirmationDialog("Retake this recording?", isPresented: $showRetakeConfirmation) {
      Button("Retake audio", role: .destructive) {
        practiceStage = .record
        retakeLastLocalAudio()
      }
      Button("Keep recording", role: .cancel) {}
    } message: {
      Text("The latest local recording may be removed. Uploaded recordings are kept.")
    }
    .sheet(isPresented: $showsSyncQueue) { SyncQueueView() }
  }

  private var practiceSyncKey: String {
    "\(networkMonitor.isOnline):\(queuedSubmissions.map(\.id).sorted().joined(separator: ","))"
  }

  @ToolbarContentBuilder private var practiceToolbar: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      PracticeNavigationTitle(courseTitle: practiceCourseTitle)
    }
    ToolbarItem(placement: .topBarLeading) {
      Button("Back", systemImage: "chevron.left", action: practiceBack)
        .accessibilityIdentifier("practice.back")
    }
    ToolbarItem(placement: .topBarTrailing) {
      Menu("Entry actions", systemImage: "ellipsis") {
        if canEditPractice {
          Button("Edit goal", action: editGoal)
          if !entry.artifacts.isEmpty {
            Button("Record another passage") { practiceStage = .record }
            Button("Retake audio") { showRetakeConfirmation = true }
          }
        }
        Button("Sync status") { showsSyncQueue = true }
        Button("Delete entry", role: .destructive) { showDeleteConfirmation = true }
      }
      .disabled(recorder.isRecording || isRequestingMicrophone)
    }
    ToolbarItemGroup(placement: .keyboard) {
      Spacer()
      Button("Done") { reflectionFocused = false }
    }
  }

  @ViewBuilder private var practiceStageContent: some View {
    switch practiceStage {
    case .record: practiceRecording
    case .reflect: practiceReflection
    case .check: practiceReview
    case .details: practiceDetails
    case .receipt: EmptyView()
    }
  }

  private var practiceRecording: some View {
    VStack(alignment: .leading, spacing: 28) {
      PracticeFlowTitle("Record a short passage.")
      practiceGoal
      PracticeRecordingMeter(recorder: recorder)
      if recorder.isRecording {
        Button("Stop recording", systemImage: "stop.fill", action: stopGuidedRecording)
          .buttonStyle(PracticeFlowButtonStyle())
          .accessibilityIdentifier("practice.stop-recording")
      } else {
        Button(
          isRequestingMicrophone ? "Preparing microphone…" : "Record audio",
          systemImage: "mic", action: requestGuidedRecording
        )
        .buttonStyle(PracticeFlowButtonStyle())
        .disabled(!canEditPractice || isRequestingMicrophone)
        .accessibilityIdentifier("practice.record")
        if !entry.artifacts.isEmpty {
          Button("Listen and reflect") { practiceStage = .reflect }
            .buttonStyle(PracticeFlowButtonStyle(primary: false))
        }
      }
      practicePrivacy(recorder.isRecording ? "Private recording on this device" : "Private draft")
    }
  }

  private var practiceReflection: some View {
    VStack(alignment: .leading, spacing: 28) {
      PracticeFlowTitle("What did you notice?")
      practiceAudio
      VStack(alignment: .leading, spacing: 8) {
        Text("Reflection (optional)").font(.subheadline)
        TextField("What did you notice?", text: $reflectionText, axis: .vertical)
          .lineLimit(3...8)
          .focused($reflectionFocused)
          .practiceField()
          .disabled(!canEditPractice)
          .accessibilityLabel("Reflection, optional")
          .accessibilityIdentifier("practice.reflection")
        if let reflectionError {
          Label(reflectionError, systemImage: "exclamationmark.circle")
            .font(.footnote).foregroundStyle(AppTheme.statusFailedForeground)
        }
      }
      practiceMetadata
      VStack(spacing: 12) {
        Button("Review submission", action: reviewPractice)
          .buttonStyle(PracticeFlowButtonStyle())
          .disabled(entry.artifacts.isEmpty || !canEditPractice)
          .accessibilityIdentifier("practice.review")
        Button("Keep as draft", action: keepPracticeDraft)
          .buttonStyle(PracticeFlowButtonStyle(primary: false))
      }
      practicePrivacy(reflectionText == (entry.notes ?? "") ? "Saved on this device" : "Reflection not saved yet")
    }
  }

  private var practiceReview: some View {
    VStack(alignment: .leading, spacing: 24) {
      PracticeFlowTitle("Ready for your teacher?")
      Text(entry.practiceDate, style: .date).foregroundStyle(PracticeFlowTheme.secondary)
      practiceGoal
      practiceAudio
      if let notes = entry.notes, !notes.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Reflection").font(.subheadline)
          Text(notes).frame(maxWidth: .infinity, alignment: .leading).practiceField()
        }
      }
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        Label("Only you until submitted", systemImage: "lock")
        Text("Teachers in \(practiceCourseTitle) can review this entry after submission.")
        Text("You cannot edit the entry after submission.")
        Label(networkMonitor.isOnline ? "Online" : "Offline", systemImage: networkMonitor.isOnline ? "wifi" : "wifi.slash")
      }
      .font(.subheadline).foregroundStyle(PracticeFlowTheme.secondary)
      if entry.artifacts.contains(where: { $0.uploadState == .failed }) {
        Button("A recording needs attention. Open sync status.") { showsSyncQueue = true }
          .font(.subheadline)
      }
      VStack(spacing: 12) {
        Button(networkMonitor.isOnline ? "Submit for review" : "Queue submission", action: submitEntry)
          .buttonStyle(PracticeFlowButtonStyle())
          .disabled(!canEditPractice || entry.artifacts.isEmpty || entry.artifacts.contains { $0.uploadState == .failed })
          .accessibilityIdentifier("practice.submit")
        Button("Keep as draft", action: keepPracticeDraft)
          .buttonStyle(PracticeFlowButtonStyle(primary: false))
      }
      practicePrivacy("Saved on this device")
    }
  }

  var practiceGoal: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Goal").font(.subheadline).foregroundStyle(PracticeFlowTheme.secondary)
      Text(entry.goalText).font(.body)
    }
  }

  var practiceMetadata: some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider()
      if let duration = entry.durationSeconds {
        LabeledContent("Practice duration", value: "\(duration / 60) min")
      }
      if !entry.tags.isEmpty { LabeledContent("Tags", value: entry.tags.joined(separator: ", ")) }
    }
    .font(.subheadline).foregroundStyle(PracticeFlowTheme.secondary)
  }

  func practicePrivacy(_ text: String) -> some View {
    Label(text, systemImage: "lock")
      .font(.footnote).foregroundStyle(PracticeFlowTheme.secondary)
      .frame(maxWidth: .infinity).padding(.top, 8)
  }
}
