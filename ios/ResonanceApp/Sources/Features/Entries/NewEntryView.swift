import SwiftUI

// Stable navigation entrypoint for creating a practice entry.

struct NewEntryView: View {
    let courseId: String
    private let initialContent: ScreenshotFormContent?
    private let wrapsInNavigationStack: Bool

    init(
        courseId: String,
        initialContent: ScreenshotFormContent? = nil,
        wrapsInNavigationStack: Bool = true
    ) {
        self.courseId = courseId
        self.initialContent = initialContent
        self.wrapsInNavigationStack = wrapsInNavigationStack
    }

    var body: some View {
        NewEntryScreen(
            courseId: courseId,
            initialContent: initialContent,
            wrapsInNavigationStack: wrapsInNavigationStack
        )
    }
}
