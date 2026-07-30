import SwiftUI

// Atelier media stage: progress-synced decorative bars, optional live level for record/play.

enum WaveformPattern {
    static let defaultHeights: [CGFloat] = [
        0.14, 0.38, 0.68, 0.31, 0.16, 0.48, 0.83, 0.36, 0.12, 0.29, 0.57, 0.86, 0.44, 0.2,
        0.16, 0.6, 0.92, 0.5, 0.24, 0.13, 0.35, 0.7, 0.42, 0.17, 0.49, 0.9, 0.56, 0.27,
        0.12, 0.37, 0.74, 0.41, 0.18, 0.3, 0.64, 0.8, 0.34, 0.15, 0.55, 0.88, 0.44, 0.22
    ]
}

private func waveformElapsedTimeLabel(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct WaveformStageView: View {
    var progress: Double
    var isActive: Bool
    var liveLevel: Double?
    var currentTimeLabel: String
    var durationLabel: String
    var onSeek: ((Double) -> Void)?
    var barCount: Int = 42
    var height: CGFloat = 96
    var accessibilitySummary: String = "Audio waveform"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levelHistory: [CGFloat] = Array(repeating: 0.18, count: 42)

    private let basePattern = WaveformPattern.defaultHeights

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(
                .animation(
                    minimumInterval: reduceMotion ? 0.5 : 0.12,
                    paused: !isActive || liveLevel != nil
                )
            ) { context in
                waveformBars(date: context.date)
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue("\(currentTimeLabel) of \(durationLabel)")

            HStack {
                Text(currentTimeLabel)
                Spacer()
                Text(durationLabel)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppTheme.workspaceMuted)
        }
        .onAppear { ensureHistorySize() }
        .onChange(of: liveLevel) { _, level in
            guard let level else { return }
            pushLevel(level)
        }
        .onChange(of: isActive) { _, active in
            if !active { averageHistoryTowardBase() }
        }
    }

    private func waveformBars(date: Date) -> some View {
        GeometryReader { proxy in
            let count = max(barCount, 8)
            let spacing: CGFloat = 2
            let barWidth = max(2, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let clampedProgress = min(max(progress, 0), 1)
            let phase = date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let fraction = CGFloat(index) / CGFloat(max(count - 1, 1))
                    Capsule(style: .continuous)
                        .fill(barColor(fraction: fraction, progress: clampedProgress))
                        .frame(
                            width: barWidth,
                            height: max(4, proxy.size.height * barHeight(at: index, count: count, phase: phase))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(seekGesture(width: proxy.size.width))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(width: 2, height: proxy.size.height * 0.9)
                    .offset(x: max(0, proxy.size.width * clampedProgress - 1))
                    .accessibilityHidden(true)
            }
        }
    }

    private func barHeight(at index: Int, count: Int, phase: TimeInterval) -> CGFloat {
        ensureHistorySize(count: count)
        if liveLevel != nil, isActive {
            return levelHistory[index % levelHistory.count]
        }
        let base = basePattern[index % basePattern.count]
        guard isActive else { return base * 0.85 }
        if reduceMotion { return base }
        let wave = 0.85 + 0.15 * sin(phase * 3 + Double(index) * 0.35)
        return min(1, base * CGFloat(wave))
    }

    private func barColor(fraction: CGFloat, progress: Double) -> Color {
        if fraction <= progress {
            return AppTheme.accent.opacity(0.55 + fraction * 0.4)
        }
        return AppTheme.accent.opacity(0.18 + (1 - fraction) * 0.12)
    }

    private func pushLevel(_ level: Double) {
        ensureHistorySize()
        let shaped = CGFloat(min(max(level, 0.06), 1))
        levelHistory.removeFirst()
        levelHistory.append(shaped)
    }

    private func averageHistoryTowardBase() {
        ensureHistorySize()
        for index in levelHistory.indices {
            let base = basePattern[index % basePattern.count]
            levelHistory[index] = levelHistory[index] * 0.4 + base * 0.6
        }
    }

    private func ensureHistorySize(count: Int? = nil) {
        let target = count ?? barCount
        if levelHistory.count != target {
            levelHistory = (0..<target).map { basePattern[$0 % basePattern.count] }
        }
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard let onSeek, width > 0 else { return }
                onSeek(min(max(value.location.x / width, 0), 1))
            }
    }
}

/// Recording-focused stage with live mic levels and elapsed time.
struct LiveRecordingStage: View {
    let duration: TimeInterval
    let averageLevel: Double
    let isRecording: Bool

    var body: some View {
        MediaStageCard(title: "Evidence · recording", status: isRecording ? .processing : .localOnly) {
            WaveformStageView(
                progress: isRecording ? min(duration / 600, 1) : 0,
                isActive: isRecording,
                liveLevel: isRecording ? averageLevel : nil,
                currentTimeLabel: waveformElapsedTimeLabel(duration),
                durationLabel: isRecording ? "Recording" : "Ready",
                accessibilitySummary: isRecording ? "Live recording waveform" : "Recording stage"
            )
        }
    }

}

/// Playback stage driven by AudioPlayer progress and optional metering.
struct LivePlaybackStage: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let averageLevel: Double?
    let onSeek: (TimeInterval) -> Void
    var title: String = "Evidence · audio"
    var status: LifecycleStatus? = nil

    var body: some View {
        MediaStageCard(title: title, status: status) {
            WaveformStageView(
                progress: duration > 0 ? currentTime / duration : 0,
                isActive: isPlaying,
                liveLevel: isPlaying ? averageLevel : nil,
                currentTimeLabel: waveformElapsedTimeLabel(currentTime),
                durationLabel: waveformElapsedTimeLabel(duration),
                onSeek: { fraction in
                    onSeek(fraction * max(duration, 0.01))
                },
                accessibilitySummary: "Audio playback waveform"
            )
        }
    }

}
