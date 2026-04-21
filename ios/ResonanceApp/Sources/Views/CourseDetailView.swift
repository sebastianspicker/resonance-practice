import SwiftUI
import SwiftData

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
                    Text("Entries").tag(0)
                    Text("Review Queue").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .accessibilityLabel("Course view")
                .accessibilityHint("Switch between practice entries and the review queue")

                if selectedTab == 0 {
                    EntryListView(courseId: course.id)
                } else {
                    TeacherQueueView(courseId: course.id)
                }
            } else {
                EntryListView(courseId: course.id)
            }
        }
        .navigationTitle(course.title)
    }
}
