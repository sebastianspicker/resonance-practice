import SwiftData
import SwiftUI

// Builds the course sidebar and exposes refresh, retry, and utility navigation actions.

extension MainSplitView {
  func teacherWorkspace(course: LocalCourse) -> some View {
    HStack(spacing: 0) {
      WorkspaceAppRail(
        showCalendar: { showCalendar = true },
        showSyncQueue: { showQueue = true },
        showSettings: { showSettings = true }
      )
      WorkspaceDivider()
      teacherCourseSidebar
        .frame(width: 200)
      WorkspaceDivider()
      TeacherQueueView(
        courseId: course.id,
        screenshotQueue: ScreenshotScenario.current == nil ? nil : screenshotReviewEntries,
        initiallyQueuedFeedback: ScreenshotScenario.current?.queuedFeedbackEntryIDs ?? [],
        presentation: .workspace,
        initialSelectedEntryID: ScreenshotScenario.current?.selectedEntryID,
        initialFeedbackContent: ScreenshotScenario.current?.feedbackContent,
        selectsInitialSubmission: ScreenshotScenario.current?.screen != .courses
      )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(AppTheme.workspaceBackground)
  }

  private var teacherCourseSidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        ResonanceMark().frame(width: 22, height: 20)
        Text("Resonance").font(.headline.weight(.semibold))
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise", action: refreshAndProcessQueue)
          .labelStyle(.iconOnly)
          .buttonStyle(.plain)
          .disabled(isRefreshing)
          .accessibilityLabel("Sync courses")
      }
      .padding(.horizontal, 24)
      .frame(height: 74)

      WorkspaceRule()
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          WorkspaceSectionLabel(title: "Courses")
            .padding(.top, 28)
            .padding(.horizontal, 24)
          ForEach(courses) { course in
            Button { selectionId = course.id } label: {
              HStack(alignment: .top, spacing: 12) {
                Image(systemName: course.roleInCourse == "teacher" ? "graduationcap" : "music.note")
                  .font(.title3)
                  .foregroundStyle(course.id == selectionId ? AppTheme.accent : AppTheme.workspaceMuted)
                  .frame(width: 26, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                  Text(course.title).font(.subheadline.weight(.medium)).lineLimit(2)
                  Text(course.roleInCourse == "teacher" ? "Teacher" : "Student")
                    .font(.caption).foregroundStyle(AppTheme.workspaceMuted)
                }
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 16).padding(.vertical, 12)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                course.id == selectionId ? AppTheme.selection : .clear,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
              )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .accessibilityLabel(
              "\(course.title), role: \(course.roleInCourse == "teacher" ? "Teacher" : "Student")"
            )
          }

          Rectangle().fill(AppTheme.workspaceBorder).frame(height: 1)
            .padding(.horizontal, 16).padding(.vertical, 16)
          WorkspaceSectionLabel(title: "Tools").padding(.horizontal, 24)
          WorkspaceSidebarButton("Calendar", icon: "calendar") { showCalendar = true }
          WorkspaceSidebarButton("Sync status", icon: "arrow.triangle.2.circlepath") {
            showQueue = true
          }
          WorkspaceSidebarButton("Settings", icon: "gearshape") { showSettings = true }
        }
      }
      connectionStatus
    }
    .background(AppTheme.workspaceSidebar)
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
    if ScreenshotScenario.current == nil {
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
    guard let session = authManager.session else { return }
    do {
      let remoteCourses = try await appState.apiClient.fetchCourses(
        accessToken: session.accessToken)
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
        modelContext: modelContext, apiClient: appState.apiClient)
      for course in remoteCourses where course.roleInCourse == "student" {
        try await reconciler.refresh(courseId: course.id, accessToken: session.accessToken)
      }
      if let selectionId, !remoteCourseIds.contains(selectionId) {
        self.selectionId = remoteCourses.first?.id
      }
    } catch { appState.reportError(error) }
  }
}

private struct WorkspaceAppRail: View {
  let showCalendar: () -> Void
  let showSyncQueue: () -> Void
  let showSettings: () -> Void

  var body: some View {
    VStack(spacing: 20) {
      ResonanceMark().frame(width: 40, height: 38).padding(.top, 18)
      Rectangle().fill(AppTheme.workspaceBorder).frame(height: 1)
      WorkspaceRailButton(icon: "square.grid.2x2.fill", label: "Courses", isSelected: true) {}
      WorkspaceRailButton(icon: "calendar", label: "Calendar", action: showCalendar)
      Spacer()
      WorkspaceRailButton(icon: "arrow.triangle.2.circlepath", label: "Sync status", action: showSyncQueue)
      WorkspaceRailButton(icon: "gearshape", label: "Settings", action: showSettings)
        .padding(.bottom, 18)
    }
    .frame(width: 64)
    .background(AppTheme.workspaceSidebar)
  }
}

private struct WorkspaceRailButton: View {
  let icon: String
  let label: String
  var isSelected = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.title3)
        .frame(width: 48, height: 48)
        .foregroundStyle(isSelected ? AppTheme.accent : Color.primary)
        .background(
          isSelected ? AppTheme.selection : .clear,
          in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

private struct WorkspaceSidebarButton: View {
  let title: String
  let icon: String
  let action: () -> Void

  init(_ title: String, icon: String, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: icon)
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.vertical, 10)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}
