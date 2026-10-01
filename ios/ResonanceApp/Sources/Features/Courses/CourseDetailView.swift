import SwiftUI
import SwiftData

// Displays the selected course and switches between its student and teacher workflows.

struct CourseDetailView: View {
    let course: LocalCourse
    @State private var selectedTab: Int

    init(course: LocalCourse, initialTab: Int = 0) {
        self.course = course
        // Initialize @State directly so the initial tab is set once at view
        // creation. Using onAppear to set it would reset the user's tab
        // selection every time the view re-appears (e.g., navigating back).
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack {
            if course.roleInCourse == "teacher" {
                Picker("View", selection: $selectedTab) {
                    Text("To review").tag(0)
                    Text("Reviewed").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .accessibilityLabel("Course view")
                .accessibilityHint("Switch between the review queue and reviewed submissions")

                if selectedTab == 0 {
                    TeacherQueueView(courseId: course.id)
                } else {
                    ContentUnavailableView(
                        "Reviewed submissions",
                        systemImage: "checkmark.circle",
                        description: Text("Submissions you have reviewed will appear here.")
                    )
                }
            } else {
                EntryListView(courseId: course.id)
            }
        }
        .background(AppTheme.workspaceBackground)
        .navigationTitle(course.title)
    }
}
