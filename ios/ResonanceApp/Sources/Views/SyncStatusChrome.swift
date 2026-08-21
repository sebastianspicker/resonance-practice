import SwiftUI

// Offline honesty banner and sync status strip shared by student and teacher shells.

struct OfflineHonestyBanner: View {
    var pendingCount: Int = 0
    var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(AppTheme.statusQueuedForeground)
                    .frame(width: 22, height: 22)
                Text("!")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Saved on this device")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.workspaceInk)
                Text(resolvedMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.workspaceInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            AppTheme.statusQueuedFill,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .stroke(AppTheme.statusQueuedForeground.opacity(0.25))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saved on this device. \(resolvedMessage)")
    }

    private var resolvedMessage: String {
        if let message, !message.isEmpty { return message }
        if pendingCount > 0 {
            let noun = pendingCount == 1 ? "item" : "items"
            return "\(pendingCount) \(noun) waiting to sync when you are back online. Your work is safe."
        }
        return "Changes are saved locally and will sync when reconnected."
    }
}

struct SyncStatusStrip: View {
    let isOnline: Bool
    let pendingCount: Int
    let failedCount: Int
    var onOpenQueue: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if !isOnline {
                OfflineHonestyBanner(pendingCount: pendingCount)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            } else if pendingCount > 0 || failedCount > 0 {
                Button {
                    onOpenQueue?()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: failedCount > 0 ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                        if failedCount > 0 {
                            Text("\(failedCount) failed")
                                .fontWeight(.semibold)
                        }
                        if pendingCount > 0 {
                            Text("\(pendingCount) queued · will sync")
                                .fontWeight(.semibold)
                        }
                        Spacer(minLength: 0)
                        if onOpenQueue != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .opacity(0.7)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(failedCount > 0 ? AppTheme.statusFailedForeground : AppTheme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        failedCount > 0 ? AppTheme.statusFailedFill : AppTheme.selection,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .disabled(onOpenQueue == nil)
                .accessibilityHint(onOpenQueue == nil ? "" : "Opens sync status")
            }

            HStack(spacing: 8) {
                if isOnline {
                    Circle()
                        .fill(AppTheme.statusReviewedForeground)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text("Online")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.workspaceMuted)
                } else {
                    StatusPill(status: .offline)
                }
                Spacer()
                if failedCount > 0 {
                    Text("\(failedCount) failed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.statusFailedForeground)
                }
                if pendingCount > 0 {
                    Text("\(pendingCount) pending")
                        .font(.caption)
                        .foregroundStyle(AppTheme.workspaceMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppTheme.workspacePanel)
            .overlay(alignment: .top) { WorkspaceRule() }
        }
        .background(AppTheme.workspacePanel)
    }
}

struct StatusRail: View {
    let items: [String]
    var leading: LifecycleStatus?

    var body: some View {
        HStack(spacing: 10) {
            if let leading {
                StatusPill(status: leading)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 || leading != nil {
                    Rectangle()
                        .fill(AppTheme.workspaceBorderStrong)
                        .frame(width: 1, height: 12)
                }
                Text(item)
                    .font(.caption)
                    .foregroundStyle(AppTheme.workspaceMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.workspacePanel)
        .overlay(alignment: .top) { WorkspaceRule() }
        .accessibilityElement(children: .combine)
    }
}

struct MediaStageCard<Content: View>: View {
    let title: String
    var status: LifecycleStatus?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                WorkspaceSectionLabel(title: title)
                Spacer()
                if let status {
                    StatusPill(status: status)
                }
            }
            content()
        }
        .padding(AppTheme.Spacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.workspacePanel)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.section, style: .continuous)
                .stroke(AppTheme.workspaceBorder)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.section, style: .continuous))
    }
}
