import SwiftUI
import SwiftData

struct SyncQueueView: View {
    @EnvironmentObject var syncManager: SyncManager
    @Query(sort: \SyncQueueItem.createdAt, order: .reverse) private var queueItems: [SyncQueueItem]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Pending")
                        Spacer()
                        Text("\(syncManager.pendingQueueCount)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Failed")
                        Spacer()
                        Text("\(syncManager.failedQueueCount)")
                            .foregroundStyle(.secondary)
                    }
                }

                if syncManager.failedQueueCount > 0 {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Some items could not sync", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text("Check your internet connection, then tap \"Retry Failed\" above. If a recording file was lost, re-record the audio from the entry detail screen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(queueItems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(friendlyTaskType(item.type))
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusDotColor(item.status))
                                .frame(width: 8, height: 8)
                            Text(item.status.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let lastError = item.lastError, item.status == "failed" {
                            Text(friendlyError(lastError))
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(friendlyTaskType(item.type)), \(item.status)")
                }
            }
            .navigationTitle("Sync Queue")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Process") {
                        Task { await syncManager.processQueue() }
                    }
                    .accessibilityHint("Processes all pending sync items")
                }
                ToolbarItem(placement: .automatic) {
                    Button("Retry Failed") {
                        syncManager.retryFailedItems()
                    }
                    .disabled(syncManager.failedQueueCount == 0)
                    .accessibilityHint("Resets failed items so they can be retried")
                }
            }
        }
    }

    private func friendlyTaskType(_ type: String) -> String {
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

    private func statusDotColor(_ status: String) -> Color {
        switch status {
        case "pending": return .yellow
        case "processing": return .blue
        case "failed": return .red
        default: return .gray
        }
    }

    private func friendlyError(_ raw: String) -> String {
        SyncErrorMessageMapper.message(for: raw)
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
        "MISSING_STORAGE_KEY": "Upload failed. Try re-recording the audio.",
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
        if ["localfilenotfound", "no such file"].contains(where: lowered.contains) {
            return "Recording file was lost. Re-record the audio."
        }
        return raw
    }

    /// Maps server error codes (from errorCodes.ts) to user-friendly messages.
    private static func message(forCode code: String) -> String {
        messagesByCode[code] ?? "Error: \(code)"
    }
}
