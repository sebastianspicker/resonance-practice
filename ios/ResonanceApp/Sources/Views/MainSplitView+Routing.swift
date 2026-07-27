import SwiftUI

// Routes normal deep links and deterministic screenshot scenarios through the app split view.

extension MainSplitView {
  @ViewBuilder var detailPane: some View {
    if let scenario = ScreenshotScenario.current, scenario.requiresAuthenticatedSession {
      screenshotDetailPane(for: scenario)
    } else {
      defaultDetailPane
    }
  }

  @ViewBuilder func screenshotDetailPane(for scenario: ScreenshotScenario) -> some View {
    switch scenario.screen {
    case .newEntry: screenshotNewEntryPane(for: scenario)
    case .entryDetail: screenshotEntryDetailPane
    case .teacherReviewQueue: screenshotReviewQueuePane
    case .submissionDetail: screenshotSubmissionDetailPane
    case .feedbackEditor: screenshotFeedbackEditorPane(for: scenario)
    case .feedbackQueued: screenshotQueuedFeedbackPane(for: scenario)
    case .reviewedFeedback: screenshotReviewedFeedbackPane(for: scenario)
    default: defaultDetailPane
    }
  }

  @ViewBuilder private func screenshotNewEntryPane(for scenario: ScreenshotScenario) -> some View {
    if let course = screenshotCourse {
      NewEntryView(
        courseId: course.id, initialContent: scenario.formContent, wrapsInNavigationStack: false)
    } else {
      defaultDetailPane
    }
  }

  @ViewBuilder private var screenshotEntryDetailPane: some View {
    if let entry = screenshotPrimaryEntry {
      EntryDetailView(entry: entry, showsArtifacts: false)
    } else {
      defaultDetailPane
    }
  }

  @ViewBuilder private var screenshotReviewQueuePane: some View {
    if let course = screenshotCourse {
      TeacherQueueView(courseId: course.id, screenshotQueue: screenshotReviewEntries)
    } else {
      defaultDetailPane
    }
  }

  @ViewBuilder private var screenshotSubmissionDetailPane: some View {
    if let entry = screenshotFeedbackEntry {
      SubmissionDetailView(entry: entry, onFeedbackQueued: {}, loadsRemoteMedia: false)
    } else {
      defaultDetailPane
    }
  }

  @ViewBuilder private func screenshotFeedbackEditorPane(for scenario: ScreenshotScenario) -> some View {
    if let entry = screenshotFeedbackEntry {
      FeedbackEditorView(entry: entry, initialContent: scenario.feedbackContent)
    } else {
      defaultDetailPane
    }
  }

  @ViewBuilder private func screenshotQueuedFeedbackPane(for scenario: ScreenshotScenario) -> some View {
    if let course = screenshotCourse {
      TeacherQueueView(
        courseId: course.id, screenshotQueue: screenshotReviewEntries,
        initiallyQueuedFeedback: scenario.queuedFeedbackEntryIDs)
    } else {
      defaultDetailPane
    }
  }

  @ViewBuilder private func screenshotReviewedFeedbackPane(for scenario: ScreenshotScenario) -> some View {
    if let entry = screenshotPrimaryEntry {
      EntryDetailView(entry: entry, initialSection: scenario.startsAtFeedback ? "feedback" : nil)
    } else {
      defaultDetailPane
    }
  }

  @ViewBuilder var defaultDetailPane: some View {
    if let course = selectedCourse {
      // Segment 0 is "To review" after the teacher tab order swap.
      CourseDetailView(course: course, initialTab: 0)
    } else {
      ContentUnavailableView(
        "Select a course", systemImage: "music.note.list",
        description: Text("Choose a course to begin."))
    }
  }

  /// Selects a deep-linked course, refreshing once when it is not yet in local storage.
  func handleOpenURL(_ url: URL) {
    guard
      let courseID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(
        where: { $0.name == "courseId" })?.value
    else { return }
    Task {
      if courses.contains(where: { $0.id == courseID }) {
        selectionId = courseID
        return
      }
      await refreshCourses()
      if courses.contains(where: { $0.id == courseID }) { selectionId = courseID }
    }
  }

  /// Applies a validated screenshot route once so capture state cannot override later user navigation.
  func applyScreenshotRoutingIfNeeded() {
    guard let scenario = ScreenshotScenario.current, scenario.requiresAuthenticatedSession,
      !didApplyScreenshotRoute
    else { return }
    let needsCourse = scenario.screen != .login
      && !(scenario.screen == .courses && scenario.persona == .student)
    if needsCourse, screenshotCourse == nil { return }
    switch scenario.screen {
    case .courses:
      selectionId = scenario.persona == .teacher ? screenshotCourse?.id : nil
    case .export:
      selectionId = screenshotCourse?.id
      showExport = true
    case .settings:
      selectionId = screenshotCourse?.id
      showSettings = true
    case .queue:
      selectionId = screenshotCourse?.id
      showQueue = true
    default: selectionId = screenshotCourse?.id
    }
    didApplyScreenshotRoute = true
  }

  var screenshotCourse: LocalCourse? {
    guard let scenario = ScreenshotScenario.current else { return nil }
    if let fixedCourse = courses.first(where: { $0.id == AppConfig.screenshotPrimaryCourseId }) {
      return fixedCourse
    }
    return courses.first(where: { $0.roleInCourse == scenario.roleInCourse }) ?? courses.first
  }

  var selectedCourse: LocalCourse? {
    guard let selectionId else { return nil }
    return courses.first { $0.id == selectionId }
  }

  var screenshotPrimaryEntry: LocalPracticeEntry? {
    guard let course = screenshotCourse, let scenario = ScreenshotScenario.current else {
      return nil
    }
    let entries = allEntries.filter { $0.courseId == course.id && $0.deletedAt == nil }
    if let id = scenario.selectedEntryID, let entry = entries.first(where: { $0.id == id }) {
      return entry
    }
    if scenario.persona == .student, let userID = authManager.session?.userId,
      let entry = entries.first(where: { $0.studentId == userID }) {
      return entry
    }
    return scenario.persona == .teacher
      ? entries.first(where: { $0.status == .submitted }) ?? entries.first : entries.first
  }

  var screenshotFeedbackEntry: ReviewQueueEntry? {
    screenshotPrimaryEntry.map(makeReviewQueueEntry)
  }

  var screenshotReviewEntries: [ReviewQueueEntry] {
    guard let course = screenshotCourse else { return [] }
    return allEntries.filter {
      $0.courseId == course.id && $0.status == .submitted && $0.deletedAt == nil
    }.sorted { $0.practiceDate > $1.practiceDate }.map(makeReviewQueueEntry)
  }

  func makeReviewQueueEntry(_ entry: LocalPracticeEntry) -> ReviewQueueEntry {
    ReviewQueueEntry(
      id: entry.id, courseId: entry.courseId, studentId: entry.studentId,
      studentName: displayName(for: entry.studentId), kind: entry.kind.rawValue,
      practiceDate: entry.practiceDate, goalText: entry.goalText, notes: entry.notes,
      consentConfirmedAt: entry.consentConfirmedAt, consentScope: entry.consentScope?.rawValue,
      captureProfile: entry.captureProfile?.rawValue,
      captureMarkerCount: entry.captureMarkers.count,
      artifacts: entry.artifacts.map {
        ArtifactResponse(
          id: $0.id, entryId: $0.entryId, type: $0.type.rawValue,
          durationSeconds: $0.durationSeconds, expectedSizeBytes: nil,
          uploadState: $0.uploadState.rawValue, storageKey: $0.storageKey, remoteUrl: $0.remoteUrl)
      })
  }

  func displayName(for studentId: String) -> String {
    switch studentId {
    case "demo_student_lea": return "Lea Sommer"
    case "demo_student_noah": return "Noah Keller"
    default: return studentId
    }
  }
}
