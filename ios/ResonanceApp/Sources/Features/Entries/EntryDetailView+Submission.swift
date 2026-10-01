import Foundation
import SwiftData

extension EntryDetailScreen {
  func submitEntry() {
    guard entry.status == .draft, authManager.session?.userId == entry.studentId else { return }
    guard !usesGuidedPractice || canEditPractice else { return }
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
    syncManager.enqueue(type: .submitEntry, payload: .entry(.init(entryId: entry.id)))
    if usesGuidedPractice { practiceStage = .receipt }
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
      syncManager.enqueue(type: .syncArtifact, payload: .artifact(.init(artifactId: artifact.id, baseVersion: nil)))
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
      syncManager.enqueue(type: .syncCaptureProfile, payload: .entry(.init(entryId: entry.id)))
    }
    if !entry.captureMarkers.isEmpty {
      syncManager.enqueue(type: .syncCaptureMarkers, payload: .entry(.init(entryId: entry.id)))
    }
  }

  func submissionArtifactError() -> String? {
    entry.artifacts.contains { $0.uploadState == .failed }
      ? "Some recordings failed to sync. Retry them before submitting." : nil
  }

  func reportSubmissionError(_ message: String) {
    if usesGuidedPractice {
      practiceError = message
      return
    }
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
      finishPractice()
    } catch { appState.reportError(error) }
  }

  func refreshFeedback() async {
    guard let session = authManager.session else { return }
    let (generation, requestID) = beginFeedbackRequest(incrementingGeneration: true)
    defer { finishFeedbackRequest(requestID) }
    do {
      let page = try await feedbackPage(accessToken: session.accessToken, cursor: nil)
      try Task.checkCancellation()
      guard isCurrentFeedbackLoad(generation, session: session) else { return }
      try applyFeedbackPage(page)
    } catch {
      reportFeedbackError(error, generation: generation, session: session)
    }
  }

  func loadMoreFeedback() {
    Task { await loadNextFeedbackPage() }
  }

  private func loadNextFeedbackPage() async {
    guard let session = authManager.session,
          let cursor = feedbackCursor,
          !cursor.isEmpty,
          !isLoadingFeedback
    else { return }
    let (generation, requestID) = beginFeedbackRequest(incrementingGeneration: false)
    defer { finishFeedbackRequest(requestID) }
    do {
      let page = try await feedbackPage(accessToken: session.accessToken, cursor: cursor)
      try Task.checkCancellation()
      guard isCurrentFeedbackLoad(generation, session: session), feedbackCursor == cursor else { return }
      try applyFeedbackPage(page)
    } catch {
      reportFeedbackError(error, generation: generation, session: session, cursor: cursor)
    }
  }

  private func isCurrentFeedbackLoad(_ generation: Int, session: AuthSession) -> Bool {
    generation == feedbackLoadGeneration &&
      authManager.session?.userId == session.userId &&
      authManager.session?.accessToken == session.accessToken
  }

  private func finishFeedbackRequest(_ requestID: UUID) {
    guard feedbackRequestID == requestID else { return }
    feedbackRequestID = nil
    isLoadingFeedback = false
  }

  private func beginFeedbackRequest(incrementingGeneration: Bool) -> (Int, UUID) {
    if incrementingGeneration { feedbackLoadGeneration &+= 1 }
    let requestID = UUID()
    feedbackRequestID = requestID
    isLoadingFeedback = true
    return (feedbackLoadGeneration, requestID)
  }

  private func feedbackPage(
    accessToken: String,
    cursor: String?
  ) async throws -> PaginatedResponse<FeedbackResponse> {
    try await appState.apiClient.fetchFeedback(
      accessToken: accessToken, entryId: entry.id, limit: 50, cursor: cursor)
  }

  /// A first page is only a partial server traversal, so cached later pages remain available offline.
  private func applyFeedbackPage(_ page: PaginatedResponse<FeedbackResponse>) throws {
    mergeFeedback(page.items)
    feedbackCursor = page.nextCursor?.isEmpty == false ? page.nextCursor : nil
    hasMoreFeedback = feedbackCursor != nil
    try modelContext.save()
  }

  private func reportFeedbackError(
    _ error: Error,
    generation: Int,
    session: AuthSession,
    cursor: String? = nil
  ) {
    guard !Task.isCancelled,
          isCurrentFeedbackLoad(generation, session: session),
          cursor == nil || feedbackCursor == cursor
    else { return }
    appState.reportError(error)
  }

  private func mergeFeedback(_ responses: [FeedbackResponse]) {
    var existingIDs = Set(entry.feedback.map(\.id))
    for feedback in responses where existingIDs.insert(feedback.id).inserted {
      let local = LocalFeedback(
        id: feedback.id, targetType: feedback.targetType, targetId: feedback.targetId,
        teacherName: feedback.teacherName,
        status: FeedbackStatus(rawValue: feedback.status) ?? .accepted,
        commentsText: feedback.commentsText)
      local.createdAt = feedback.createdAt
      for marker in feedback.markers {
        let localMarker = LocalMarker(
          id: marker.id, timeSeconds: marker.timeSeconds, text: marker.text)
        modelContext.insert(localMarker)
        local.markers.append(localMarker)
      }
      entry.feedback.append(local)
      modelContext.insert(local)
    }
  }
}
