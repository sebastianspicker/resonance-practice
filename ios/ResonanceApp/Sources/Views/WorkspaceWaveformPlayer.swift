import SwiftUI

// Illustrated audio stage for screenshot / offline demo playback (no remote media).

struct WorkspaceWaveformPlayer: View {
    let duration: Int

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Authorized course media · not cached", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.workspaceMuted)
                GeometryReader { proxy in
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(Array(WaveformPattern.defaultHeights.enumerated()), id: \.offset) { index, height in
                            Capsule()
                                .fill(barFill(for: index))
                                .frame(
                                    width: max(2, (proxy.size.width - 82) / CGFloat(WaveformPattern.defaultHeights.count)),
                                    height: max(4, proxy.size.height * height)
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .center) {
                        Rectangle()
                            .fill(AppTheme.accent)
                            .frame(width: 2)
                            .offset(x: proxy.size.width * 0.03)
                    }
                }
                .frame(height: 112)
                HStack {
                    Text("00:00")
                    Spacer()
                    Text(format(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.workspaceMuted)
            }
            .padding(16)
            .background(
                AppTheme.workspaceRaised,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.section, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.section, style: .continuous)
                    .stroke(AppTheme.workspaceBorder)
            )

            HStack(spacing: 28) {
                Button("Playback speed", systemImage: "1.circle") {}
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Playback speed")
                Button("Skip back 10 seconds", systemImage: "gobackward.10") {}
                    .labelStyle(.iconOnly)
                Button("Play", systemImage: "play.fill") {}
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .padding(15)
                    .background(AppTheme.accent, in: Circle())
                    .foregroundStyle(.white)
                    .accessibilityLabel("Play")
                Button("Skip forward 10 seconds", systemImage: "goforward.10") {}
                    .labelStyle(.iconOnly)
                Spacer()
                Label(format(duration), systemImage: "speaker.wave.2")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(AppTheme.workspaceInkSoft)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.workspaceInk)
            .accessibilityElement(children: .contain)
        }
    }

    private func barFill(for index: Int) -> Color {
        // Soft accent gradient along the timeline; playhead sits slightly past start.
        let progress = CGFloat(index) / CGFloat(max(WaveformPattern.defaultHeights.count - 1, 1))
        if progress < 0.35 {
            return AppTheme.accent.opacity(0.55 + progress * 0.9)
        }
        return AppTheme.accent.opacity(0.22 + (1 - progress) * 0.18)
    }

    private func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct WorkspaceTimelineRow: View {
    let time: String
    let text: String
    let isAccent: Bool

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(isAccent ? AppTheme.accent : AppTheme.workspaceBorderStrong)
                .frame(width: 10, height: 10)
                .overlay {
                    if isAccent {
                        Circle().stroke(AppTheme.accent.opacity(0.35), lineWidth: 4)
                    }
                }
            Text(time)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(isAccent ? AppTheme.accent : AppTheme.workspaceInk)
                .frame(width: 50, alignment: .leading)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(isAccent ? AppTheme.accent : AppTheme.workspaceInkSoft)
            Spacer(minLength: 0)
            Image(systemName: "bookmark")
                .foregroundStyle(AppTheme.workspaceMuted)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { WorkspaceRule() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Marker \(time): \(text)")
    }
}
