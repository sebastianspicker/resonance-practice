#if RESONANCE_SCREENSHOTS
import Foundation

/// Deterministic session injection is compiled with the app only for demos and screenshots.
@MainActor
extension AuthManager {
    func signInForScreenshot(role: ScreenshotPersona) async throws {
        let isTeacher = role == .teacher
        session = AuthSession(
            accessToken: "screenshot-only-access-token",
            refreshToken: "screenshot-only-refresh-token",
            userId: isTeacher ? DemoConfiguration.screenshotTeacherUserId : DemoConfiguration.screenshotStudentUserId,
            displayName: isTeacher ? "Prof. Weber" : "Lea Hoffmann",
            globalRole: "user"
        )
        authError = nil
    }
}
#endif
