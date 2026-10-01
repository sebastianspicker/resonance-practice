import SwiftUI

// Illustrated audio stage for screenshot / offline demo playback (no remote media).

struct WorkspaceWaveformPlayer: View {
    let duration: Int

    var body: some View {
        VStack(spacing: 14) {
            Label("Authorized course media · not cached", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(AppTheme.stageMuted)
            WaveformStageView(
                progress: 0.03,
                isActive: false,
                liveLevel: nil,
                currentTimeLabel: "0:00",
                durationLabel: format(duration),
                height: 112,
                accessibilitySummary: "Illustrated audio waveform, ready to play",
                markers: markers,
                usesDarkStage: true
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
                    .foregroundStyle(AppTheme.stageInk)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.stageInk)
            .accessibilityElement(children: .contain)
        }
    }

    private var markers: [WaveformStageMarker] {
        [
            .init(id: "opening", timeLabel: "0:38", fraction: 0.19, title: "Opening carries well"),
            .init(id: "crescendo", timeLabel: "1:24", fraction: 0.42, title: "Build the crescendo earlier", isActive: true),
            .init(id: "closing", timeLabel: "2:47", fraction: 0.84, title: "Let the closing phrase breathe")
        ]
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
