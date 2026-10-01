#if RESONANCE_SCREENSHOTS
import Foundation

// Defines validated capture-build personas, routes, and deterministic content for screenshot capture.

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
    case practiceReflect = "practice-reflect"
    case practiceReview = "practice-review"
    case practiceQueued = "practice-queued"
    case practiceSubmitted = "practice-submitted"
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
        case .practiceReflect, .practiceReview, .practiceQueued, .practiceSubmitted:
            return "demo_entry_lea_guided_practice"
        case .reviewedFeedback:
            return "demo_entry_lea_reviewed_1"
        case .submissionDetail, .feedbackEditor, .feedbackQueued:
            return "demo_entry_lea_submitted_1"
        default:
            return nil
        }
    }

    var newEntryPrefill: NewEntryPrefill? {
        screen == .newEntry ? Self.walkthroughEntry : nil
    }

    var feedbackPrefill: FeedbackPrefill? {
        screen == .feedbackEditor ? Self.walkthroughFeedback : nil
    }

    private static let walkthroughEntry = NewEntryPrefill(
        goalText: "Shape the opening phrase with an even legato line",
        durationMinutes: "25",
        tags: "chopin, legato, phrasing",
        notes: "Keep the left hand quiet and compare takes at 72 bpm."
    )

    private static let walkthroughFeedback = FeedbackPrefill(
        status: .nextGoal,
        commentsText: "The phrase is much more connected. Next, keep the release light before increasing the tempo.",
        markers: [
            MarkerDraft(time: "00:18", text: "Excellent voicing here."),
            MarkerDraft(time: "00:41", text: "Keep the wrist relaxed through the release.")
        ]
    )

    var startsAtFeedback: Bool {
        screen == .reviewedFeedback
    }

    var isGuidedPracticeScreen: Bool {
        switch screen {
        case .practiceReflect, .practiceReview, .practiceQueued, .practiceSubmitted:
            true
        default:
            false
        }
    }

    var guidedPracticeInitialSection: String? {
        screen == .practiceReview ? "guided-check" : nil
    }

    var needsOfflineGuidedPracticeState: Bool {
        screen == .practiceReview || screen == .practiceQueued
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
#endif
