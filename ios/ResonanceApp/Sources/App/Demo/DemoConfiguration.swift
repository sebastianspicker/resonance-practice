import Foundation

/// Deterministic local-only values for screenshots and the bundled demo.
enum DemoConfiguration {
    static let universityName = ProcessInfo.processInfo.environment["RESONANCE_DEMO_UNIVERSITY_NAME"]
        ?? "Mock University Conservatory"
#if RESONANCE_SCREENSHOTS
    static let screenshotStudentUserId = ProcessInfo.processInfo.environment["RESONANCE_SCREENSHOT_STUDENT_USER_ID"]
        ?? "demo_student_lea"
    static let screenshotTeacherUserId = ProcessInfo.processInfo.environment["RESONANCE_SCREENSHOT_TEACHER_USER_ID"]
        ?? "demo_teacher_anna"
    static let screenshotPrimaryCourseId = ProcessInfo.processInfo.environment["RESONANCE_SCREENSHOT_PRIMARY_COURSE_ID"]
        ?? "demo_course_piano"
#endif
}
