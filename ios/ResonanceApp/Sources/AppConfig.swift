import Foundation

// Centralizes validated runtime endpoints and deterministic demo/screenshot identifiers.
enum AppConfig {
    private static let defaultAPIBaseURL = URL(string: "http://localhost:4000")!
    static let apiBaseURL = resolveAPIBaseURL(
        ProcessInfo.processInfo.environment["RESONANCE_API_BASE"]
    )
    static let authLoginURL = apiBaseURL.appendingPathComponent("auth/login")

    /// Accepts a credential-free HTTP(S) origin/path or falls back to the loopback API.
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
    static let screenshotPrimaryCourseId =
        ProcessInfo.processInfo.environment["RESONANCE_SCREENSHOT_PRIMARY_COURSE_ID"] ?? "demo_course_piano"
    static let authCallbackScheme = "resonance"
    static let authCallbackURL = URL(string: "resonance://auth-callback")!

    /// Server API routes are versioned at an absolute path. Do not append this
    /// to a configurable base URL because a base such as `/tenant/` would
    /// otherwise produce a different endpoint.
    static func apiV1URL(path: String) -> URL {
        guard var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            return apiBaseURL
        }
        components.path = "/api/v1/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        return components.url ?? apiBaseURL
    }
    static let keychainNamespace: String = {
        let base = apiBaseURL.absoluteString.lowercased()
        let sanitized = base
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "resonance-default" : "resonance-\(sanitized)"
    }()
}
