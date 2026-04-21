import SwiftUI
import SwiftData

// TODO: Localization — All user-facing strings in this view should be wrapped with
// LocalizedStringKey / NSLocalizedString for i18n support.
struct MainSplitView: View {
    let modelContext: ModelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @Query(sort: \LocalCourse.title) private var courses: [LocalCourse]
    @Query(sort: \LocalPracticeEntry.practiceDate, order: .reverse) private var allEntries: [LocalPracticeEntry]
    @State private var selectionId: String?
    @State private var showCalendar = false
    @State private var showExport = false
    @State private var showSettings = false
    @State private var showQueue = false
    @State private var isRefreshing = false
    @State private var didApplyScreenshotRoute = false

    var body: some View {
        NavigationSplitView {
            ZStack {
                AppTheme.PremiumBackground()
                
                List(courses, selection: $selectionId) { course in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(course.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Text(course.roleInCourse.capitalized)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 8)
                    .tag(course.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(course.title), role: \(course.roleInCourse)")
                    .accessibilityHint("Double-tap to view course details")
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.white.opacity(0.1).cornerRadius(12).padding(.vertical, 4))
                }
                .scrollContentBackground(.hidden)
                .safeAreaPadding(.horizontal, 12)
                .overlay {
                    if isRefreshing { ProgressView().scaleEffect(1.2).tint(.white) }
                }
            }
            .navigationTitle("Courses")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if ScreenshotScenario.current == nil {
                    VStack(spacing: 0) {
                        if !networkMonitor.isOnline {
                            HStack(spacing: 6) {
                                Image(systemName: "wifi.slash")
                                    .font(.caption.weight(.bold))
                                Text("You are offline. Changes are saved locally and will sync when reconnected.")
                                    .font(.caption)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.85))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Offline. Changes are saved locally and will sync when reconnected.")
                        }
                        VStack(spacing: 2) {
                            HStack {
                                Circle()
                                    .fill(networkMonitor.isOnline ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(networkMonitor.isOnline ? "Online" : "Offline")
                                Spacer()
                                if syncManager.failedQueueCount > 0 {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                        Text("\(syncManager.failedQueueCount) failed")
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if syncManager.pendingQueueCount > 0 {
                                    Text("\(syncManager.pendingQueueCount) pending")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Network \(networkMonitor.isOnline ? "online" : "offline"), \(syncManager.pendingQueueCount) pending, \(syncManager.failedQueueCount) failed")
                            if let lastSync = syncManager.lastSyncedAt {
                                Text("Last synced \(lastSync, style: .relative) ago")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Sync") {
                        Task {
                            isRefreshing = true
                            await refreshCourses()
                            await syncManager.processQueue()
                            isRefreshing = false
                        }
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("Sync courses")
                    .accessibilityHint("Double-tap to refresh courses and process the sync queue")
                }
                ToolbarItem(placement: .automatic) {
                    Menu("Actions") {
                        Button("Queue") {
                            showQueue = true
                        }
                        .accessibilityLabel("View sync queue")
                        .accessibilityHint("Double-tap to open the sync queue")
                        Button("Retry Failed") {
                            syncManager.retryFailedItems()
                            Task { await syncManager.processQueue() }
                        }
                        .disabled(syncManager.failedQueueCount == 0)
                        .accessibilityLabel("Retry failed sync items")
                        .accessibilityHint("Double-tap to retry all failed queue items")
                        Button("Calendar") {
                            showCalendar = true
                        }
                        .accessibilityLabel("Open calendar")
                        .accessibilityHint("Double-tap to view your calendar events")
                        Button("Export") {
                            showExport = true
                        }
                        .accessibilityLabel("Export data")
                        .accessibilityHint("Double-tap to export your practice data")
                        Button("Settings") {
                            showSettings = true
                        }
                        .accessibilityLabel("Open settings")
                        .accessibilityHint("Double-tap to open app settings")
                    }
                    .accessibilityLabel("Actions menu")
                    .accessibilityHint("Double-tap to show available actions")
                }
            }
        } detail: {
            ZStack {
                AppTheme.PremiumBackground()
                detailPane
            }
            .safeAreaPadding(.horizontal, 12)
        }
        .sheet(isPresented: $showCalendar) {
            CalendarView()
        }
        .sheet(isPresented: $showExport) {
            ExportView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showQueue) {
            SyncQueueView()
        }
        .onOpenURL { url in
            if let courseId = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "courseId" })?.value {
                Task {
                    if courses.contains(where: { $0.id == courseId }) {
                        selectionId = courseId
                        return
                    }
                    await refreshCourses()
                    if courses.contains(where: { $0.id == courseId }) {
                        selectionId = courseId
                    }
                }
            }
        }
        .task {
            if courses.isEmpty {
                await refreshCourses()
            }
            applyScreenshotRoutingIfNeeded()
        }
        .onChange(of: courses.count) { _, _ in
            applyScreenshotRoutingIfNeeded()
        }
    }

    private func refreshCourses() async {
        guard let session = authManager.session else { return }
        do {
            let remoteCourses = try await appState.apiClient.fetchCourses(accessToken: session.accessToken)
            let existing = (try? modelContext.fetch(FetchDescriptor<LocalCourse>())) ?? []
            let existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

            for course in remoteCourses {
                if let local = existingMap[course.id] {
                    local.title = course.title
                    local.roleInCourse = course.roleInCourse
                } else {
                    let record = LocalCourse(id: course.id, title: course.title, roleInCourse: course.roleInCourse)
                    modelContext.insert(record)
                }
            }
            try modelContext.save()
        } catch {
            appState.reportError(error)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let scenario = ScreenshotScenario.current, scenario.requiresAuthenticatedSession {
            switch scenario.screen {
            case .entryDetail:
                if let entry = screenshotPrimaryEntry {
                    EntryDetailView(entry: entry)
                } else {
                    defaultDetailPane
                }
            case .teacherReviewQueue:
                if let course = screenshotCourse {
                    TeacherQueueView(courseId: course.id)
                } else {
                    defaultDetailPane
                }
            case .feedbackEditor:
                if let reviewEntry = screenshotFeedbackEntry {
                    FeedbackEditorView(entry: reviewEntry)
                } else {
                    defaultDetailPane
                }
            default:
                defaultDetailPane
            }
        } else {
            defaultDetailPane
        }
    }

    @ViewBuilder
    private var defaultDetailPane: some View {
        if let selectionId, let course = courses.first(where: { $0.id == selectionId }) {
            let initialTab = (ScreenshotScenario.current?.screen == .teacherReviewQueue) ? 1 : 0
            CourseDetailView(course: course, initialTab: initialTab)
        } else {
            ContentUnavailableView {
                Label("Select a course", systemImage: "music.note.list")
                    .foregroundStyle(.white)
            } description: {
                Text("Choose a course to begin.")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func applyScreenshotRoutingIfNeeded() {
        guard let scenario = ScreenshotScenario.current, scenario.requiresAuthenticatedSession else {
            return
        }
        guard !didApplyScreenshotRoute else {
            return
        }

        let needsCourse = scenario.screen != .courses && scenario.screen != .login
        if needsCourse, screenshotCourse == nil {
            return
        }

        switch scenario.screen {
        case .courses:
            selectionId = nil
        case .export:
            selectionId = screenshotCourse?.id
            showExport = true
        case .settings:
            selectionId = screenshotCourse?.id
            showSettings = true
        case .queue:
            selectionId = screenshotCourse?.id
            showQueue = true
        default:
            selectionId = screenshotCourse?.id
        }

        didApplyScreenshotRoute = true
    }

    private var screenshotCourse: LocalCourse? {
        guard let scenario = ScreenshotScenario.current else {
            return nil
        }
        if let fixedCourse = courses.first(where: { $0.id == AppConfig.screenshotPrimaryCourseId }) {
            return fixedCourse
        }
        let preferredRole = scenario.roleInCourse
        return courses.first(where: { $0.roleInCourse == preferredRole }) ?? courses.first
    }

    private var screenshotPrimaryEntry: LocalPracticeEntry? {
        guard let course = screenshotCourse, let scenario = ScreenshotScenario.current else {
            return nil
        }
        let entriesInCourse = allEntries.filter { $0.courseId == course.id && $0.deletedAt == nil }
        switch scenario.persona {
        case .student:
            if let currentUserId = authManager.session?.userId,
               let ownEntry = entriesInCourse.first(where: { $0.studentId == currentUserId }) {
                return ownEntry
            }
            return entriesInCourse.first
        case .teacher:
            if let submitted = entriesInCourse.first(where: { $0.status == .submitted }) {
                return submitted
            }
            return entriesInCourse.first
        }
    }

    private var screenshotFeedbackEntry: ReviewQueueEntry? {
        guard let entry = screenshotPrimaryEntry else {
            return nil
        }
        return ReviewQueueEntry(
            id: entry.id,
            courseId: entry.courseId,
            studentId: entry.studentId,
            studentName: displayName(for: entry.studentId),
            practiceDate: entry.practiceDate,
            goalText: entry.goalText,
            notes: entry.notes,
            artifacts: entry.artifacts.map {
                ArtifactResponse(
                    id: $0.id,
                    entryId: $0.entryId,
                    type: $0.type.rawValue,
                    durationSeconds: $0.durationSeconds,
                    uploadState: $0.uploadState.rawValue,
                    storageKey: $0.storageKey,
                    remoteUrl: $0.remoteUrl
                )
            }
        )
    }

    private func displayName(for studentId: String) -> String {
        switch studentId {
        case "demo_student_lea":
            return "Lea Sommer"
        case "demo_student_noah":
            return "Noah Keller"
        default:
            return studentId
        }
    }
}
