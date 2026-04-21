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
        case "createArtifact": return "Create Recording"
        case "uploadArtifact": return "Upload Recording"
        case "confirmArtifact": return "Confirm Upload"
        case "submitEntry": return "Submit Entry"
        case "deleteEntry": return "Delete Entry"
        case "postFeedback": return "Send Feedback"
        case "syncArtifact": return "Sync Recording"
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
        // Try to parse structured JSON error response: { "error": { "code": "...", "message": "..." } }
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let code = errorObj["code"] as? String {
            return friendlyMessageForCode(code)
        }

        // Fallback: string-based matching for non-JSON errors (e.g. network/system errors)
        let lowered = raw.lowercased()
        if lowered.contains("urlerror") || lowered.contains("network") || lowered.contains("timed out") || lowered.contains("not connected") {
            return "Network connection failed. Check your internet."
        }
        if lowered.contains("localfilenotfound") || lowered.contains("no such file") {
            return "Recording file was lost. Re-record the audio."
        }
        return raw
    }

    /// Maps server error codes (from errorCodes.ts) to user-friendly messages.
    private func friendlyMessageForCode(_ code: String) -> String {
        switch code {
        // Auth
        case "MISSING_AUTH", "INVALID_TOKEN", "INVALID_REFRESH",
             "REFRESH_REVOKED", "REFRESH_MISMATCH", "REFRESH_ALREADY_USED":
            return "Session expired. Sign out and sign in again."
        case "INVALID_CODE":
            return "Login code is invalid or expired. Try signing in again."
        case "USER_NOT_FOUND":
            return "Account not found. Contact your administrator."
        case "DEV_AUTH_LOCAL_ONLY":
            return "Dev login is only available locally."
        case "AUTH_NOT_CONFIGURED":
            return "Authentication is not configured on the server."
        case "INVALID_ROLE":
            return "Your account role does not permit this action."

        // Authorization
        case "STUDENT_ONLY":
            return "This action is only available for students."
        case "TEACHER_ONLY", "TEACHER_REQUIRED":
            return "This action requires teacher access."
        case "ENTRY_ACCESS_DENIED", "COURSE_ACCESS_DENIED":
            return "You don't have access to this resource."

        // Resources
        case "NOT_FOUND", "ENTRY_NOT_FOUND", "ARTIFACT_NOT_FOUND", "COURSE_NOT_FOUND":
            return "The requested item was not found on the server."
        case "ENTRY_DELETED":
            return "This entry has been deleted."

        // State
        case "ENTRY_LOCKED":
            return "This entry is locked and cannot be modified."
        case "ENTRY_NOT_SUBMITTED":
            return "This entry has not been submitted yet."
        case "ARTIFACTS_NOT_UPLOADED":
            return "Audio files have not finished uploading."
        case "UPLOAD_INVALID", "MISSING_STORAGE_KEY":
            return "Upload failed. Try re-recording the audio."
        case "INVALID_TARGET":
            return "Invalid target for this operation."

        // Validation
        case "VALIDATION_ERROR":
            return "Server rejected this data. Check the entry fields."
        case "ID_CONFLICT":
            return "This item already exists on the server."

        // Generic
        case "INTERNAL_ERROR":
            return "Server error. Try again later."
        case "RATE_LIMITED":
            return "Too many requests. Please wait a moment."

        default:
            return "Error: \(code)"
        }
    }
}
