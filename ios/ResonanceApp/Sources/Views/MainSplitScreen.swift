import SwiftData
import SwiftUI

// Owns split-view selection, presentation state, refresh work, and screenshot routing.

struct MainSplitScreen: View {
  let modelContext: ModelContext
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var authManager: AuthManager
  @EnvironmentObject var syncManager: SyncManager
  @EnvironmentObject var networkMonitor: NetworkMonitor
  @Query(sort: \LocalCourse.title) var courses: [LocalCourse]
  @Query(sort: \LocalPracticeEntry.practiceDate, order: .reverse) var allEntries:
    [LocalPracticeEntry]
  @State var selectionId: String?
  @State var showCalendar = false
  @State var showExport = false
  @State var showSettings = false
  @State var showQueue = false
  @State var isRefreshing = false
  @State var didApplyScreenshotRoute = false

  var body: some View {
    GeometryReader { proxy in
      if usesTeacherWorkspace(at: proxy.size.width), let course = selectedCourse {
        teacherWorkspace(course: course)
      } else {
        compactOrStandardSplitView
      }
    }
    .sheet(isPresented: $showCalendar) { CalendarView() }
    .sheet(isPresented: $showExport) { ExportView() }
    .sheet(isPresented: $showSettings) { SettingsView() }
    .sheet(isPresented: $showQueue) { SyncQueueView() }
    .onOpenURL(perform: handleOpenURL)
    .task {
      if courses.isEmpty { await refreshCourses() }
      applyScreenshotRoutingIfNeeded()
    }
    .onChange(of: courses.count) { _, _ in applyScreenshotRoutingIfNeeded() }
  }

  private var compactOrStandardSplitView: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detailPane
    }
  }

  private func usesTeacherWorkspace(at width: CGFloat) -> Bool {
    width >= AppTheme.compactBreakpoint && selectedCourse?.roleInCourse == "teacher"
  }
}
