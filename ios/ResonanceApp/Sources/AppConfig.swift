import Foundation

enum AppConfig {
    private static let defaultAPIBaseURL = URL(string: "http://localhost:4000")!
    static let apiBaseURL = resolveAPIBaseURL(
        ProcessInfo.processInfo.environment["RESONANCE_API_BASE"]
    )
    static let authLoginURL = apiBaseURL.appendingPathComponent("auth/login")

    static func resolveAPIBaseURL(_ value: String?) -> URL {
        guard let value, !value.isEmpty,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return defaultAPIBaseURL
        }
        return url
    }

    // MARK: - Demo / screenshot-only defaults
    // These IDs are used exclusively for local development, UI previews,
    // and automated screenshot capture.  They do NOT grant access to any
    // real data and must never appear in a production build.
    static let demoUniversityName = ProcessInfo.processInfo.environment["RESONANCE_DEMO_UNIVERSITY_NAME"] ?? "Mock University Conservatory"
    static let screenshotStudentUserId = ProcessInfo.processInfo.environment["RESONANCE_SCREENSHOT_STUDENT_USER_ID"] ?? "demo_student_lea"
    static let screenshotTeacherUserId = ProcessInfo.processInfo.environment["RESONANCE_SCREENSHOT_TEACHER_USER_ID"] ?? "demo_teacher_anna"
    static let screenshotPrimaryCourseId = ProcessInfo.processInfo.environment["RESONANCE_SCREENSHOT_PRIMARY_COURSE_ID"] ?? "demo_course_piano"
    static let authCallbackScheme = "resonance"
    static let authCallbackURL = URL(string: "resonance://auth-callback")!
    static let keychainNamespace: String = {
        let base = apiBaseURL.absoluteString.lowercased()
        let sanitized = base
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "resonance-default" : "resonance-\(sanitized)"
    }()
}
