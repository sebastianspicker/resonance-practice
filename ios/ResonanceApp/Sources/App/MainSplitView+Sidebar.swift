import SwiftData
import SwiftUI

// Builds the course sidebar and exposes refresh, retry, and utility navigation actions.

extension MainSplitView {
  func teacherWorkspace(course: LocalCourse) -> some View {
    NavigationStack {
      teacherWorkspaceQueue(courseId: course.id)
        .navigationTitle(course.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Menu("Courses", systemImage: "rectangle.grid.1x2") {
              ForEach(courses) { candidate in
                Button(candidate.title) { selectionId = candidate.id }
              }
            }
            .accessibilityLabel("Switch course")
          }
          ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Calendar", systemImage: "calendar") { showCalendar = true }
            Button("Sync status", systemImage: "arrow.triangle.2.circlepath") { showQueue = true }
            Button("Settings", systemImage: "gearshape") { showSettings = true }
          }
        }
    }
    .background(AppTheme.workspaceBackground)
  }

  private func teacherWorkspaceQueue(courseId: String) -> TeacherQueueView {
#if RESONANCE_SCREENSHOTS
    if let scenario = ScreenshotScenario.current {
      return TeacherQueueView(
        courseId: courseId,
        presetQueue: screenshotReviewEntries,
        initiallyQueuedFeedback: scenario.queuedFeedbackEntryIDs,
        presentation: .workspace,
        initialSelectedEntryID: scenario.selectedEntryID,
        initialFeedback: scenario.feedbackPrefill,
        selectsInitialSubmission: scenario.screen != .courses
      )
    }
#endif
    return TeacherQueueView(courseId: courseId, presentation: .workspace)
  }

  var sidebar: some View {
    List(selection: $selectionId) {
      Section("Courses") {
        ForEach(courses) { course in
          VStack(alignment: .leading, spacing: 4) {
            Text(course.title).font(.headline).lineLimit(2)
            Text(course.roleInCourse == "teacher" ? "Teacher" : "Student").font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
          .tag(course.id)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(course.title), role: \(course.roleInCourse)")
          .accessibilityHint("Opens the course")
        }
      }
      Section("Tools") {
        Button("Calendar", systemImage: "calendar") { showCalendar = true }
        if selectedCourse?.roleInCourse == "student" {
          Button("Export", systemImage: "square.and.arrow.up") { showExport = true }
        }
        Button("Sync status", systemImage: "arrow.triangle.2.circlepath") { showQueue = true }
        Button("Settings", systemImage: "gearshape") { showSettings = true }
      }
    }
    .overlay { if isRefreshing { ProgressView("Refreshing…") } }
    .navigationTitle("Courses")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom, spacing: 0) { connectionStatus }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Sync", action: refreshAndProcessQueue)
          .disabled(isRefreshing)
          .accessibilityLabel("Sync courses")
          .accessibilityHint("Double-tap to refresh courses and process the sync queue")
      }
      ToolbarItem(placement: .automatic) {
        Button("Retry failed", systemImage: "arrow.clockwise", action: retryFailedItems)
          .disabled(syncManager.failedQueueCount == 0)
      }
    }
  }

  @ViewBuilder var connectionStatus: some View {
    if !capturePresentation {
      SyncStatusStrip(
        isOnline: networkMonitor.isOnline,
        pendingCount: syncManager.pendingQueueCount,
        failedCount: syncManager.failedQueueCount,
        onOpenQueue: { showQueue = true }
      )
    }
  }

  func refreshAndProcessQueue() {
    Task {
      isRefreshing = true
      await refreshCourses()
      await syncManager.processQueue()
      isRefreshing = false
    }
  }

  func retryFailedItems() {
    syncManager.retryFailedItems()
    Task { await syncManager.processQueue() }
  }

  func refreshCourses() async {
    refreshGeneration &+= 1
    let generation = refreshGeneration
    guard let session = authManager.session else { return }
    let userID = session.userId
    let accessToken = session.accessToken
    do {
      let remoteCourses = try await appState.apiClient.fetchCourses(
        accessToken: accessToken)
      try Task.checkCancellation()
      guard isCurrentProfile(userID: userID, accessToken: accessToken, generation: generation) else { return }
      let existing = (try? modelContext.fetch(FetchDescriptor<LocalCourse>())) ?? []
      let existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
      let remoteCourseIds = Set(remoteCourses.map(\.id))
      for course in remoteCourses {
        if let local = existingMap[course.id] {
          local.title = course.title
          local.roleInCourse = course.roleInCourse
        } else {
          modelContext.insert(
            LocalCourse(id: course.id, title: course.title, roleInCourse: course.roleInCourse))
        }
      }
      for localCourse in existing where !remoteCourseIds.contains(localCourse.id) {
        modelContext.delete(localCourse)
      }
      try modelContext.save()
      let reconciler = EntryReconciliationService(
        modelContext: modelContext,
        apiClient: appState.apiClient,
        ownerId: userID,
        isCurrentProfile: {
          isCurrentProfile(userID: userID, accessToken: accessToken, generation: generation)
        }
      )
      for course in remoteCourses where course.roleInCourse == "student" {
        try await reconciler.refresh(courseId: course.id, accessToken: accessToken)
        try Task.checkCancellation()
        guard isCurrentProfile(userID: userID, accessToken: accessToken, generation: generation) else { return }
      }
      if let selectionId, !remoteCourseIds.contains(selectionId) {
        self.selectionId = remoteCourses.first?.id
      }
    } catch is CancellationError {
      return
    } catch {
      errorReporter.report(error)
    }
  }

  private func isCurrentProfile(userID: String, accessToken: String, generation: Int) -> Bool {
    refreshGeneration == generation && authManager.session?.userId == userID &&
      authManager.session?.accessToken == accessToken
  }
}
