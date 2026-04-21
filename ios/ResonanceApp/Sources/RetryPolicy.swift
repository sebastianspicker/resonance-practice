import Foundation

/// Stateless retry policy for sync queue items.
///
/// Provides backoff delay calculation and terminal-error classification
/// so `SyncManager` does not embed retry logic inline.
struct RetryPolicy {
    let maxAttempts: Int

    init(maxAttempts: Int = 20) {
        self.maxAttempts = maxAttempts
    }

    /// Exponential back-off capped at 5 minutes: `min(2^retryCount, 300)`.
    func backoffDelay(retryCount: Int) -> TimeInterval {
        min(pow(2.0, Double(retryCount)), 300)
    }

    /// Returns `true` when the error is terminal — the item should be
    /// marked failed immediately rather than retried.
    func isTerminal(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            return isTerminalAPIError(apiError)
        }
        if error is SyncError {
            return true
        }
        if (error as NSError).domain == "SyncLocal", (error as NSError).code == 404 {
            return true
        }
        return false
    }

    // MARK: - Private helpers

    private func isTerminalAPIError(_ error: APIError) -> Bool {
        switch error.error.code {
        case "VALIDATION_ERROR",
             "ENTRY_LOCKED",
             "ENTRY_NOT_SUBMITTED",
             "ARTIFACTS_NOT_UPLOADED",
             "MISSING_STORAGE_KEY",
             "INVALID_TARGET",
             "STUDENT_ONLY",
             "TEACHER_ONLY",
             "ENTRY_ACCESS_DENIED",
             "COURSE_ACCESS_DENIED",
             "DEV_AUTH_LOCAL_ONLY",
             "AUTH_NOT_CONFIGURED",
             "INVALID_ROLE",
             "USER_NOT_FOUND":
            return true
        default:
            return false
        }
    }
}
