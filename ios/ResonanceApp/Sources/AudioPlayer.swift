import Foundation
import AVFoundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "AudioPlayer")

enum ArtifactPlaybackSourceError: LocalizedError {
    case authenticationRequired

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Sign in again to play this recording."
        }
    }
}

@MainActor
struct ArtifactPlaybackSourceResolver {
    let apiClient: APIClient
    var fileManager: FileManager = .default

    func resolve(artifact: LocalArtifact, accessToken: String?) async throws -> URL {
        if !artifact.localPath.isEmpty, fileManager.fileExists(atPath: artifact.localPath) {
            return URL(fileURLWithPath: artifact.localPath)
        }
        guard let accessToken else {
            throw ArtifactPlaybackSourceError.authenticationRequired
        }
        return try await apiClient.fetchArtifactDownloadURL(
            accessToken: accessToken,
            artifactId: artifact.id
        ).downloadUrl
    }
}

@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published private(set) var currentFilePath: String?
    @Published private(set) var playbackError: String?

    private var player: AVAudioPlayer?
    private var streamPlayer: AVPlayer?
    private var timer: Timer?
    private var streamEndObserver: NSObjectProtocol?
    private var streamFailureObserver: NSObjectProtocol?

    @discardableResult
    func play(url: URL) -> Bool {
        resetPlaybackState()
        playbackError = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            if url.isFileURL {
                player = try AVAudioPlayer(contentsOf: url)
                player?.delegate = self
                duration = player?.duration ?? 0
                guard player?.play() == true else {
                    playbackError = "Playback could not be started."
                    resetPlaybackState()
                    deactivateAudioSession()
                    return false
                }
            } else {
                let item = AVPlayerItem(url: url)
                observeStreamItem(item)
                let streamPlayer = AVPlayer(playerItem: item)
                self.streamPlayer = streamPlayer
                streamPlayer.play()
            }
            isPlaying = true
            currentFilePath = url.path
            startTimer()
            return true
        } catch {
            logger.error("Audio playback failed for \(url.lastPathComponent): \(error.localizedDescription)")
            playbackError = error.localizedDescription
            resetPlaybackState()
            deactivateAudioSession()
            return false
        }
    }

    func stop() {
        playbackError = nil
        resetPlaybackState()
        deactivateAudioSession()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration)
        player?.currentTime = clamped
        streamPlayer?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let player = self.player {
                    self.currentTime = player.currentTime
                } else if let streamPlayer = self.streamPlayer {
                    if let item = streamPlayer.currentItem, item.status == .failed {
                        self.failStreamPlayback(item.error?.localizedDescription ?? "Playback failed.")
                        return
                    }
                    let currentTime = streamPlayer.currentTime().seconds
                    self.currentTime = currentTime.isFinite ? currentTime : 0
                    let duration = streamPlayer.currentItem?.duration.seconds ?? 0
                    if duration.isFinite && duration > 0 {
                        self.duration = duration
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func resetPlaybackState() {
        player?.stop()
        streamPlayer?.pause()
        stopTimer()
        removeStreamObservers()
        player = nil
        streamPlayer = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentFilePath = nil
    }

    private func observeStreamItem(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        streamEndObserver = center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishStreamPlayback()
            }
        }
        streamFailureObserver = center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? "Playback failed."
            Task { @MainActor [weak self] in
                self?.failStreamPlayback(message)
            }
        }
    }

    private func removeStreamObservers() {
        let center = NotificationCenter.default
        if let streamEndObserver {
            center.removeObserver(streamEndObserver)
            self.streamEndObserver = nil
        }
        if let streamFailureObserver {
            center.removeObserver(streamFailureObserver)
            self.streamFailureObserver = nil
        }
    }

    private func finishStreamPlayback() {
        resetPlaybackState()
        deactivateAudioSession()
    }

    private func failStreamPlayback(_ message: String) {
        playbackError = message
        resetPlaybackState()
        deactivateAudioSession()
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
