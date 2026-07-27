import SwiftUI

// Atelier status pills: lifecycle and sync state always include a text label (color is supplementary).

enum LifecycleStatus: Equatable, Hashable {
    case draft
    case localOnly
    case queued
    case submitted
    case reviewed
    case failed
    case offline
    case feedbackQueued
    case processing

    var label: String {
        switch self {
        case .draft: return "Draft"
        case .localOnly: return "Local only"
        case .queued: return "Queued"
        case .submitted: return "Submitted"
        case .reviewed: return "Reviewed"
        case .failed: return "Sync failed"
        case .offline: return "Offline"
        case .feedbackQueued: return "Feedback queued"
        case .processing: return "Syncing"
        }
    }

    var fill: Color {
        switch self {
        case .draft: return AppTheme.statusDraftFill
        case .localOnly: return AppTheme.statusLocalFill
        case .queued, .feedbackQueued, .processing: return AppTheme.statusQueuedFill
        case .submitted: return AppTheme.statusSubmittedFill
        case .reviewed: return AppTheme.statusReviewedFill
        case .failed: return AppTheme.statusFailedFill
        case .offline: return AppTheme.statusOfflineFill
        }
    }

    var foreground: Color {
        switch self {
        case .draft: return AppTheme.statusDraftForeground
        case .localOnly: return AppTheme.statusLocalForeground
        case .queued, .feedbackQueued, .processing: return AppTheme.statusQueuedForeground
        case .submitted: return AppTheme.statusSubmittedForeground
        case .reviewed: return AppTheme.statusReviewedForeground
        case .failed: return AppTheme.statusFailedForeground
        case .offline: return AppTheme.statusOfflineForeground
        }
    }
}

struct StatusPill: View {
    let status: LifecycleStatus
    var showsDot: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                Circle()
                    .fill(status.foreground)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text(status.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(status.foreground)
        .background(status.fill, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.label)")
    }
}

extension EntryStatus {
    var displayLabel: String {
        switch self {
        case .draft: return "Draft"
        case .submitted: return "Submitted"
        case .reviewed: return "Reviewed"
        }
    }

    var lifecycleStatus: LifecycleStatus {
        switch self {
        case .draft: return .draft
        case .submitted: return .submitted
        case .reviewed: return .reviewed
        }
    }

    /// Student-facing lifecycle that elevates local-only drafts.
    func studentLifecycle(isRemoteBacked: Bool) -> LifecycleStatus {
        switch self {
        case .draft:
            return isRemoteBacked ? .draft : .localOnly
        case .submitted:
            return .submitted
        case .reviewed:
            return .reviewed
        }
    }
}

extension ArtifactSyncPhase {
    var lifecycleStatus: LifecycleStatus {
        switch self {
        case .queued: return .queued
        case .uploading, .confirming: return .processing
        case .uploaded: return .submitted
        case .failed: return .failed
        }
    }

    var displayLabel: String {
        lifecycleStatus.label
    }
}

extension FeedbackStatus {
    var displayLabel: String {
        switch self {
        case .accepted: return "On track"
        case .needsRevision: return "Needs revision"
        case .nextGoal: return "Next goal"
        }
    }

    var tint: Color {
        switch self {
        case .accepted: return AppTheme.statusReviewedForeground
        case .needsRevision: return AppTheme.statusQueuedForeground
        case .nextGoal: return AppTheme.statusLocalForeground
        }
    }
}
