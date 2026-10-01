import SwiftUI

// Composes the sync queue's stable list, status rows, and retry controls.

struct SyncQueueState {
    let items: [SyncQueueItem]
    let pendingCount: Int
    let failedCount: Int

    var isEmpty: Bool {
        pendingCount == 0 && failedCount == 0 && items.isEmpty
    }
}

struct SyncQueueContent: View {
    let state: SyncQueueState

    var body: some View {
        Group {
            if state.isEmpty {
                ContentUnavailableView(
                    "No sync work",
                    systemImage: "checkmark.circle",
                    description: Text("Pending and failed items will appear here.")
                )
            } else {
                List {
                    SyncQueueSummarySection(
                        pendingCount: state.pendingCount,
                        failedCount: state.failedCount
                    )

                    if state.failedCount > 0 {
                        SyncQueueFailureGuidance()
                    }

                    ForEach(state.items) { item in
                        SyncQueueItemRow(item: item)
                    }
                }
            }
        }
    }
}

struct SyncQueueSummarySection: View {
    let pendingCount: Int
    let failedCount: Int

    var body: some View {
        Section {
            HStack {
                Text("Pending")
                Spacer()
                Text("\(pendingCount)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Failed")
                Spacer()
                Text("\(failedCount)")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SyncQueueFailureGuidance: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Some items could not sync", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(
                    "Check your internet connection, then tap \"Retry Failed\" above. If a recording file was " +
                        "lost, re-record the audio from the entry detail screen."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct SyncQueueItemRow: View {
    let item: SyncQueueItem

    private var taskType: String {
        SyncQueueDisplay.taskType(for: item.type)
    }

    private var lifecycleStatus: LifecycleStatus {
        SyncQueueDisplay.lifecycleStatus(for: item.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(taskType)
                .font(.subheadline.weight(.semibold))
            StatusPill(status: lifecycleStatus)
            if let lastError = item.lastError, item.status == "failed" {
                Text(SyncErrorMessageMapper.message(for: lastError))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.statusFailedForeground)
                    .lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(taskType), \(lifecycleStatus.label)")
    }
}

struct SyncQueueToolbar: ToolbarContent {
    let isQueueEmpty: Bool
    let failedCount: Int
    let processQueue: () -> Void
    let retryFailed: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Process", action: processQueue)
                .disabled(isQueueEmpty)
                .accessibilityHint("Processes all pending sync items")
        }
        ToolbarItem(placement: .automatic) {
            Button("Retry Failed", action: retryFailed)
                .disabled(failedCount == 0)
                .accessibilityHint("Resets failed items so they can be retried")
        }
    }
}

enum SyncQueueDisplay {
    static func taskType(for type: String) -> String {
        switch type {
        case "createEntry": return "Create Entry"
        case "submitEntry": return "Submit Entry"
        case "deleteEntry": return "Delete Entry"
        case "postFeedback": return "Send Feedback"
        case "syncArtifact": return "Sync Recording"
        case "syncCaptureProfile": return "Sync Camera Profile"
        case "syncCaptureMarkers": return "Sync Lesson Markers"
        default: return type
        }
    }

    static func lifecycleStatus(for status: String) -> LifecycleStatus {
        switch status {
        case "pending": return .queued
        case "processing": return .processing
        case "failed": return .failed
        default: return .queued
        }
    }
}

enum SyncErrorMessageMapper {
    private static let messagesByCode: [String: String] = [
        "MISSING_AUTH": "Session expired. Sign out and sign in again.",
        "INVALID_TOKEN": "Session expired. Sign out and sign in again.",
        "INVALID_REFRESH": "Session expired. Sign out and sign in again.",
        "REFRESH_REVOKED": "Session expired. Sign out and sign in again.",
        "REFRESH_MISMATCH": "Session expired. Sign out and sign in again.",
        "REFRESH_ALREADY_USED": "Session expired. Sign out and sign in again.",
        "INVALID_CODE": "Login code is invalid or expired. Try signing in again.",
        "USER_NOT_FOUND": "Account not found. Contact your administrator.",
        "DEV_AUTH_LOCAL_ONLY": "Dev login is only available locally.",
        "AUTH_NOT_CONFIGURED": "Authentication is not configured on the server.",
        "INVALID_ROLE": "Your account role does not permit this action.",
        "STUDENT_ONLY": "This action is only available for students.",
        "TEACHER_ONLY": "This action requires teacher access.",
        "TEACHER_REQUIRED": "This action requires teacher access.",
        "ENTRY_ACCESS_DENIED": "You don't have access to this resource.",
        "COURSE_ACCESS_DENIED": "You don't have access to this resource.",
        "NOT_FOUND": "The requested item was not found on the server.",
        "ENTRY_NOT_FOUND": "The requested item was not found on the server.",
        "ARTIFACT_NOT_FOUND": "The requested item was not found on the server.",
        "COURSE_NOT_FOUND": "The requested item was not found on the server.",
        "ENTRY_DELETED": "This entry has been deleted.",
        "ENTRY_LOCKED": "This entry is locked and cannot be modified.",
        "ENTRY_NOT_SUBMITTED": "This entry has not been submitted yet.",
        "ARTIFACTS_NOT_UPLOADED": "Audio files have not finished uploading.",
        "UPLOAD_INVALID": "Upload failed. Try re-recording the audio.",
        "STORAGE_UNAVAILABLE": "Media storage is unavailable. Try again later.",
        "INVALID_TARGET": "Invalid target for this operation.",
        "VALIDATION_ERROR": "Server rejected this data. Check the entry fields.",
        "ID_CONFLICT": "This item already exists on the server.",
        "INTERNAL_ERROR": "Server error. Try again later.",
        "RATE_LIMITED": "Too many requests. Please wait a moment."
    ]

    static func message(for raw: String) -> String {
        if let code = serverErrorCode(in: raw) {
            return message(forCode: code)
        }
        return fallbackMessage(for: raw)
    }

    private static func serverErrorCode(in raw: String) -> String? {
        if messagesByCode[raw] != nil {
            return raw
        }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return nil
        }
        return error["code"] as? String
    }

    private static func fallbackMessage(for raw: String) -> String {
        let lowered = raw.lowercased()
        if ["urlerror", "network", "timed out", "not connected"].contains(where: lowered.contains) {
            return "Network connection failed. Check your internet."
        }
        if ["localfilenotfound", "local file not found", "no such file"].contains(where: lowered.contains) {
            return "Recording file was lost. Re-record the audio."
        }
        return raw
    }

    /// Maps server error codes (from errorCodes.ts) to user-friendly messages.
    private static func message(forCode code: String) -> String {
        messagesByCode[code] ?? "Error: \(code)"
    }
}
