import AVFoundation
import SwiftData
import SwiftUI

// Implements recording, capture-profile, and server-conflict actions for an entry detail screen.

extension EntryDetailView {
  var captureProfileSelection: Binding<CaptureProfile> {
    Binding(get: { entry.captureProfile ?? .teacherLearner }, set: { updateCaptureProfile($0) })
  }

  var draftInstruction: String {
    entry.kind == .teachingLesson
      ? "Film or import a lesson video, then submit for course review."
      : "Record audio above, then submit for your teacher to review."
  }

  func startRecording() {
    guard entry.status == .draft else {
      reportSubmissionError("Only draft entries can be recorded.")
      return
    }
    let url = FileStore.createAudioFileURL(entryId: entry.id)
    do { try recorder.startRecording(to: url) } catch { appState.reportError(error) }
  }

  func reloadServerCopy() {
    Task { @MainActor in
      do { try await syncManager.reloadServerCopy(of: entry) } catch { appState.reportError(error) }
    }
  }

  func duplicateAsNewDraft() {
    do {
      _ = try syncManager.duplicateAsNewDraft(entry, modelContext: modelContext)
      dismiss()
    } catch { appState.reportError(error) }
  }

  func stopRecording() {
    recorder.stopRecording()
    guard let url = recorder.lastURL else {
      reportSubmissionError("Recording file is unavailable.")
      return
    }
    guard recorder.duration > 0, FileManager.default.fileExists(atPath: url.path) else {
      FileStore.deleteFileIfExists(atPath: url.path)
      reportSubmissionError("Recording did not complete, so no audio was attached.")
      return
    }
    let artifact = LocalArtifact(
      id: UUID().uuidString, entryId: entry.id, type: .audio,
      durationSeconds: Int(recorder.duration), localPath: url.path)
    entry.artifacts.append(artifact)
    modelContext.insert(artifact)
    guard saveEntryChanges() else { return }
    syncManager.enqueue(type: .syncArtifact, payload: ["artifactId": artifact.id])
  }

  func updateCaptureProfile(_ profile: CaptureProfile) {
    guard entry.captureProfile != profile else { return }
    entry.captureProfile = profile
    entry.updatedAt = Date()
    guard saveEntryChanges() else { return }
    syncManager.enqueue(type: .syncCaptureProfile, payload: ["entryId": entry.id])
  }

  @discardableResult
  func ensureTeachingLessonCaptureProfile() -> Bool {
    guard entry.kind == .teachingLesson, entry.captureProfile == nil else { return false }
    entry.captureProfile = .teacherLearner
    entry.updatedAt = Date()
    return true
  }

  /// Records private-course-review confirmation on a teaching-lesson draft and queues metadata sync.
  func confirmPrivateCourseReviewConsent() {
    guard entry.kind == .teachingLesson, entry.status == .draft else { return }
    guard entry.consentConfirmedAt == nil || entry.consentScope == nil else { return }
    entry.consentConfirmedAt = Date()
    entry.consentScope = .privateCourseReview
    entry.updatedAt = Date()
    guard saveEntryChanges() else { return }
    syncManager.enqueue(type: .updateEntry, payload: ["entryId": entry.id])
  }

  func updateGoalText(_ text: String) {
    guard entry.status == .draft else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != entry.goalText else { return }
    entry.goalText = trimmed
    entry.updatedAt = Date()
    guard saveEntryChanges() else { return }
    syncManager.enqueue(type: .updateEntry, payload: ["entryId": entry.id])
  }

  /// Removes the last local pending/queued audio when possible, then starts a new recording.
  func retakeLastLocalAudio() {
    guard entry.status == .draft else { return }

    let retakeCandidates = entry.artifacts
      .filter { $0.type == .audio && !$0.localPath.isEmpty }
      .filter { $0.syncPhase == .queued || $0.uploadState == .pending }
      .sorted { $0.createdAt < $1.createdAt }

    if let artifact = retakeCandidates.last {
      if playingArtifactID == artifact.id {
        playbackTask?.cancel()
        player.stop()
        playingArtifactID = nil
      }
      FileStore.deleteFileIfExists(atPath: artifact.localPath)
      entry.artifacts.removeAll { $0.id == artifact.id }
      modelContext.delete(artifact)
      guard saveEntryChanges() else { return }
    }

    startRecording()
  }

  func attachLessonVideo(_ result: Result<[URL], Error>) async {
    guard hasTeachingLessonConsent() else {
      reportSubmissionError("Confirm private course review before filming or importing.")
      return
    }
    do {
      guard let sourceURL = try result.get().first else { return }
      let didAccess = sourceURL.startAccessingSecurityScopedResource()
      defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
      let destination = FileStore.createVideoFileURL(
        entryId: entry.id,
        fileExtension: sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension)
      try FileManager.default.copyItem(at: sourceURL, to: destination)
      FileStore.setFileProtection(url: destination)
      let artifact = LocalArtifact(
        id: UUID().uuidString, entryId: entry.id, type: .video,
        durationSeconds: await videoDurationSeconds(url: destination), localPath: destination.path)
      let didSetDefaultProfile = ensureTeachingLessonCaptureProfile()
      entry.artifacts.append(artifact)
      modelContext.insert(artifact)
      try modelContext.save()
      if didSetDefaultProfile {
        syncManager.enqueue(type: .syncCaptureProfile, payload: ["entryId": entry.id])
      }
    } catch { appState.reportError(error) }
  }

  func finishLessonCapture(_ result: TeachingLessonCaptureResult) {
    guard hasTeachingLessonConsent() else {
      reportSubmissionError("Confirm private course review before filming or importing.")
      return
    }
    let artifact = LocalArtifact(
      id: UUID().uuidString, entryId: entry.id, type: .video,
      durationSeconds: result.durationSeconds, localPath: result.videoURL.path)
    entry.captureProfile = result.captureProfile
    entry.updatedAt = Date()
    entry.artifacts.append(artifact)
    modelContext.insert(artifact)
    for markerDraft in result.markers {
      let marker = LocalCaptureMarker(
        id: markerDraft.id, entryId: entry.id, artifactId: artifact.id,
        timeSeconds: markerDraft.timeSeconds, kind: markerDraft.kind, note: markerDraft.note)
      entry.captureMarkers.append(marker)
      modelContext.insert(marker)
    }
    do { try modelContext.save() } catch {
      appState.reportError(error)
      return
    }
    syncManager.enqueue(type: .syncCaptureProfile, payload: ["entryId": entry.id])
  }

  func videoDurationSeconds(url: URL) async -> Int {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration) else { return 0 }
    let seconds = CMTimeGetSeconds(duration)
    return seconds.isFinite && seconds > 0 ? Int(seconds.rounded()) : 0
  }

  private func hasTeachingLessonConsent() -> Bool {
    if entry.kind != .teachingLesson { return true }
    return entry.consentConfirmedAt != nil && entry.consentScope != nil
  }

  private func saveEntryChanges() -> Bool {
    do {
      try modelContext.save()
      return true
    } catch {
      appState.reportError(error)
      return false
    }
  }
}
