import Foundation
import SwiftData

// Coordinates submission, teaching-lesson metadata, deletion, and feedback refresh actions.

extension EntryDetailView {
  func submitEntry() {
    guard !entry.artifacts.isEmpty else {
      reportSubmissionError("At least one recording is required before submitting.")
      return
    }
    guard prepareTeachingLessonSubmission() else { return }
    if let artifactError = submissionArtifactError() {
      reportSubmissionError(artifactError)
      return
    }
    do { try modelContext.save() } catch {
      appState.reportError(error)
      return
    }
    syncManager.enqueue(type: .submitEntry, payload: ["entryId": entry.id])
  }

  func prepareTeachingLessonSubmission() -> Bool {
    guard entry.kind == .teachingLesson else { return true }
    guard entry.consentConfirmedAt != nil, entry.consentScope != nil else {
      reportSubmissionError(
        "Confirm private course review before submitting this teaching lesson.")
      return false
    }
    let videos = entry.artifacts.filter { $0.type == .video }
    guard !videos.isEmpty else {
      reportSubmissionError("Film or import a lesson video before submitting this teaching lesson.")
      return false
    }
    enqueueTeachingLessonMetadata(didSetDefaultProfile: ensureTeachingLessonCaptureProfile())
    let localVideos = videos.filter { $0.uploadState == .pending }
    guard !localVideos.isEmpty else { return true }
    for artifact in localVideos {
      artifact.uploadState = .uploading
      artifact.syncPhase = .queued
      syncManager.enqueue(type: .syncArtifact, payload: ["artifactId": artifact.id])
    }
    do {
      try modelContext.save()
      return true
    } catch {
      appState.reportError(error)
      return false
    }
  }

  func enqueueTeachingLessonMetadata(didSetDefaultProfile: Bool) {
    if didSetDefaultProfile || entry.captureProfile != nil {
      syncManager.enqueue(type: .syncCaptureProfile, payload: ["entryId": entry.id])
    }
    if !entry.captureMarkers.isEmpty {
      syncManager.enqueue(type: .syncCaptureMarkers, payload: ["entryId": entry.id])
    }
  }

  func submissionArtifactError() -> String? {
    entry.artifacts.contains { $0.uploadState == .failed }
      ? "Some recordings failed to sync. Retry them before submitting." : nil
  }

  func reportSubmissionError(_ message: String) {
    appState.reportError(
      NSError(domain: "Resonance", code: 0, userInfo: [NSLocalizedDescriptionKey: message]))
  }

  /// Delegates destructive entry removal to the coordinator so local and remote work stay consistent.
  func deleteEntry() {
    playbackTask?.cancel()
    player.stop()
    if recorder.isRecording { recorder.stopRecording() }
    let stoppedRecorderPath = recorder.lastURL?.path
    do {
      _ = try EntryDeletionCoordinator.delete(
        entry: entry, modelContext: modelContext, ownerId: authManager.session?.userId,
        additionalOwnedMediaPaths: stoppedRecorderPath.map { [$0] } ?? [])
      dismiss()
    } catch { appState.reportError(error) }
  }

  func refreshFeedback() async {
    guard let session = authManager.session else { return }
    isLoadingFeedback = true
    defer { isLoadingFeedback = false }
    do {
      let feedbackList = try await appState.apiClient.fetchFeedback(
        accessToken: session.accessToken, entryId: entry.id)
      let oldFeedback = entry.feedback
      entry.feedback.removeAll()
      for old in oldFeedback { modelContext.delete(old) }
      for feedback in feedbackList {
        let local = LocalFeedback(
          id: feedback.id, targetType: feedback.targetType, targetId: feedback.targetId,
          teacherName: feedback.teacherName,
          status: FeedbackStatus(rawValue: feedback.status) ?? .accepted,
          commentsText: feedback.commentsText)
        for marker in feedback.markers {
          let localMarker = LocalMarker(
            id: marker.id, timeSeconds: marker.timeSeconds, text: marker.text)
          modelContext.insert(localMarker)
          local.markers.append(localMarker)
        }
        entry.feedback.append(local)
        modelContext.insert(local)
      }
      try modelContext.save()
    } catch { appState.reportError(error) }
  }
}
