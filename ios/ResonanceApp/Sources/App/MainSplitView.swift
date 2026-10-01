import SwiftData
import SwiftUI

// Owns split-view selection, presentation state, refresh work, and screenshot routing.

struct MainSplitView: View {
  let modelContext: ModelContext
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var authManager: AuthManager
  @EnvironmentObject var syncManager: SyncManager
  @EnvironmentObject var networkMonitor: NetworkMonitor
  @EnvironmentObject var errorReporter: ErrorReporter
  @Environment(\.capturePresentation) var capturePresentation
  @Query(sort: \LocalCourse.title) var courses: [LocalCourse]
  @Query(sort: \LocalPracticeEntry.practiceDate, order: .reverse) var allEntries:
    [LocalPracticeEntry]
  @State var selectionId: String?
  @State var showCalendar = false
  @State var showExport = false
  @State var showSettings = false
  @State var showQueue = false
  @State var isRefreshing = false
  @State var refreshGeneration = 0
#if RESONANCE_SCREENSHOTS
  @State var didApplyScreenshotRoute = false
#endif

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
    .sheet(isPresented: $showSettings) {
      SettingsView(
        signOutAndDeleteLocalData: { await appState.signOutAndDeleteLocalData() },
        demoData: demoDataActions
      )
    }
    .sheet(isPresented: $showQueue) { SyncQueueView() }
    .onOpenURL(perform: handleOpenURL)
    .task {
      if courses.isEmpty { await refreshCourses() }
#if RESONANCE_SCREENSHOTS
      applyScreenshotRoutingIfNeeded()
#endif
    }
#if RESONANCE_SCREENSHOTS
    .onChange(of: courses.count) { _, _ in applyScreenshotRoutingIfNeeded() }
#endif
  }

  /// Debug and capture builds expose mock-university loading in Settings; other builds compile it out.
  private var demoDataActions: SettingsDemoDataActions? {
#if DEBUG || RESONANCE_SCREENSHOTS
    let manager = DemoDataManager(modelContext: modelContext)
    return SettingsDemoDataActions(
      load: { try manager.loadMockUniversityData(roleInCourse: $0) },
      clear: { try manager.clearMockUniversityData() }
    )
#else
    return nil
#endif
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
