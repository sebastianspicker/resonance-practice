import Foundation

// Defines validated debug-only personas, routes, and deterministic content for screenshot capture.

enum ScreenshotPersona: String {
    case student
    case teacher
}

enum ScreenshotScreen: String {
    case login = "login"
    case courses = "courses"
    case entryList = "entry-list"
    case newEntry = "new-entry"
    case entryDetail = "entry-detail"
    case export = "export"
    case settings = "settings"
    case queue = "queue"
    case teacherReviewQueue = "teacher-review-queue"
    case submissionDetail = "submission-detail"
    case feedbackEditor = "feedback-editor"
    case feedbackQueued = "feedback-queued"
    case reviewedFeedback = "reviewed-feedback"
}

struct ScreenshotFormContent: Equatable {
    let goalText: String
    let durationMinutes: String
    let tags: String
    let notes: String

    static let walkthrough = ScreenshotFormContent(
        goalText: "Shape the opening phrase with an even legato line",
        durationMinutes: "25",
        tags: "chopin, legato, phrasing",
        notes: "Keep the left hand quiet and compare takes at 72 bpm."
    )
}

struct ScreenshotFeedbackContent: Equatable {
    let status: FeedbackStatus
    let commentsText: String
    let markers: [MarkerDraft]

    static let walkthrough = ScreenshotFeedbackContent(
        status: .nextGoal,
        commentsText: "The phrase is much more connected. Next, keep the release light before increasing the tempo.",
        markers: [
            MarkerDraft(time: "00:18", text: "Excellent voicing here."),
            MarkerDraft(time: "00:41", text: "Keep the wrist relaxed through the release.")
        ]
    )
}

/// Complete capture route derived only from explicitly enabled screenshot environment values.
struct ScreenshotScenario {
    let persona: ScreenshotPersona
    let screen: ScreenshotScreen

    var requiresAuthenticatedSession: Bool {
        screen != .login
    }

    var roleInCourse: String {
        persona == .teacher ? "teacher" : "student"
    }

    var selectedEntryID: String? {
        switch screen {
        case .entryDetail:
            return "demo_entry_lea_draft_1"
        case .reviewedFeedback:
            return "demo_entry_lea_reviewed_1"
        case .submissionDetail, .feedbackEditor, .feedbackQueued:
            return "demo_entry_lea_submitted_1"
        default:
            return nil
        }
    }

    var formContent: ScreenshotFormContent? {
        screen == .newEntry ? .walkthrough : nil
    }

    var feedbackContent: ScreenshotFeedbackContent? {
        screen == .feedbackEditor ? .walkthrough : nil
    }

    var startsAtFeedback: Bool {
        screen == .reviewedFeedback
    }

    var queuedFeedbackEntryIDs: Set<String> {
        screen == .feedbackQueued ? ["demo_entry_lea_submitted_1"] : []
    }

    static var current: ScreenshotScenario? {
        from(environment: ProcessInfo.processInfo.environment)
    }

    /// Returns a scenario only when capture mode and all required values pass strict validation.
    static func from(environment env: [String: String]) -> ScreenshotScenario? {
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
