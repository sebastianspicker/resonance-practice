import Foundation

enum ScreenshotPersona: String {
    case student
    case teacher
}

enum ScreenshotScreen: String {
    case login = "login"
    case courses = "courses"
    case entryList = "entry-list"
    case entryDetail = "entry-detail"
    case export = "export"
    case settings = "settings"
    case queue = "queue"
    case teacherReviewQueue = "teacher-review-queue"
    case feedbackEditor = "feedback-editor"
}

struct ScreenshotScenario {
    let persona: ScreenshotPersona
    let screen: ScreenshotScreen

    var requiresAuthenticatedSession: Bool {
        screen != .login
    }

    var roleInCourse: String {
        persona == .teacher ? "teacher" : "student"
    }

    static var current: ScreenshotScenario? {
        let env = ProcessInfo.processInfo.environment
        guard env["RESONANCE_SCREENSHOT_MODE"] == "1" else {
            return nil
        }
        let personaRaw = env["RESONANCE_SCREENSHOT_ROLE"] ?? ScreenshotPersona.student.rawValue
        let screenRaw = env["RESONANCE_SCREENSHOT_SCREEN"] ?? ScreenshotScreen.courses.rawValue
        guard let persona = ScreenshotPersona(rawValue: personaRaw),
              let screen = ScreenshotScreen(rawValue: screenRaw) else {
            return nil
        }
        return ScreenshotScenario(persona: persona, screen: screen)
    }
}
