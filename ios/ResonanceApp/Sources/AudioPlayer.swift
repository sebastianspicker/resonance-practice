import Foundation
import AVFoundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "AudioPlayer")

@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published private(set) var currentFilePath: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(url: URL) {
        player?.stop()
        stopTimer()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            duration = player?.duration ?? 0
            guard player?.play() == true else {
                resetPlaybackState()
                deactivateAudioSession()
                return
            }
            isPlaying = true
            currentFilePath = url.path
            startTimer()
        } catch {
            logger.error("Audio playback failed for \(url.lastPathComponent): \(error.localizedDescription)")
            resetPlaybackState()
            deactivateAudioSession()
        }
    }

    func stop() {
        player?.stop()
        stopTimer()
        player = nil
        isPlaying = false
        currentTime = 0
        currentFilePath = nil
        duration = 0
        deactivateAudioSession()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration)
        player?.currentTime = clamped
        currentTime = clamped
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = self.player?.currentTime ?? 0
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func resetPlaybackState() {
        player?.stop()
        stopTimer()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentFilePath = nil
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.warning("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = 0
            self.currentFilePath = nil
            self.stopTimer()
            self.deactivateAudioSession()
        }
    }
}
