import AVFoundation
import SwiftUI

extension EntryDetailView {
  /// Keep visible submissions moving through the existing queue's upload dependencies and retry policy.
  func continuePracticeSubmission() async {
    guard !capturePresentation else { return }
    while !Task.isCancelled && networkMonitor.isOnline && !queuedSubmissions.isEmpty && entry.status == .draft {
      guard deliveryState != .failed else { return }
      await syncManager.processQueue()
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
  }

  func beginGuidedPracticeIfNeeded() {
    guard startsWithRecording, !didStartGuidedRecording else { return }
    didStartGuidedRecording = true
    requestGuidedRecording()
  }

  func requestGuidedRecording() {
    guard canEditPractice, !recorder.isRecording, !isRequestingMicrophone else { return }
    practiceError = nil
    isRequestingMicrophone = true
    Task { @MainActor in
      let allowed = await AVAudioApplication.requestRecordPermission()
      isRequestingMicrophone = false
      guard canEditPractice, isPracticeVisible else { return }
      guard allowed else {
        reportSubmissionError("Allow microphone access in Settings to record. Your draft is saved.")
        return
      }
      player.stop()
      playingArtifactID = nil
      startRecording()
    }
  }

  func stopGuidedRecording() {
    if finishRecording() { practiceStage = .reflect }
  }

  func practiceBack() {
    if recorder.isRecording {
      showRecordingExitConfirmation = true
    } else if practiceStage == .check && canEditPractice {
      practiceStage = .reflect
    } else {
      keepPracticeDraft()
    }
  }

  func reviewPractice() {
    guard savePracticeReflection() else { return }
    practiceError = nil
    player.stop()
    practiceStage = .check
    reflectionFocused = false
  }

  func keepPracticeDraft() {
    guard savePracticeReflection() else { return }
    finishPractice()
  }

  func finishPractice() {
    if let onFinish { onFinish() } else { dismiss() }
  }

  @discardableResult
  func savePracticeReflection() -> Bool {
    guard canEditPractice, reflectionText != (entry.notes ?? "") else { return true }
    guard reflectionText.count <= 10_000 else {
      reflectionError = "Reflection must contain no more than 10,000 characters."
      reflectionFocused = true
      return false
    }
    let previousNotes = entry.notes
    let previousDate = entry.updatedAt
    entry.notes = reflectionText.isEmpty ? nil : reflectionText
    entry.updatedAt = Date()
    do {
      try modelContext.save()
      syncManager.enqueue(type: .updateEntry, payload: .entry(.init(entryId: entry.id)))
      reflectionError = nil
      return true
    } catch {
      entry.notes = previousNotes
      entry.updatedAt = previousDate
      reflectionError = "Your reflection could not be saved. Try again."
      errorReporter.report(error)
      return false
    }
  }
}
