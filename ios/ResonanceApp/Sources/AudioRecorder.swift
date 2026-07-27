import Foundation
import AVFoundation
import os

// Wraps AVAudioRecorder for short local practice-entry recordings.

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "AudioRecorder")

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    enum RecorderError: LocalizedError {
        case failedToStart

        var errorDescription: String? {
            switch self {
            case .failedToStart:
                return "Recording could not be started"
            }
        }
    }

    @Published var isRecording: Bool = false
    @Published var duration: TimeInterval = 0
    /// Normalized 0…1 average input level for live waveform feedback (not stored as analysis).
    @Published private(set) var averageLevel: Double = 0

    private var recorder: AVAudioRecorder?
    private(set) var lastURL: URL?
    private var timer: Timer?

    func startRecording(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }

        guard recorder?.record() == true else {
            recorder = nil
            lastURL = nil
            averageLevel = 0
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecorderError.failedToStart
        }

        lastURL = url
        isRecording = true
        startTimer()
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        averageLevel = 0
        stopTimer()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.warning("Failed to deactivate audio session after recording: \(error.localizedDescription)")
        }
        if let lastURL {
            FileStore.setFileProtection(url: lastURL)
        }
    }

    private func startTimer() {
        duration = 0
        averageLevel = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder else { return }
                self.duration = recorder.currentTime
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                // Map typical speech/instrument range (~-50…0 dB) into 0…1.
                let normalized = Double((power + 50) / 50)
                self.averageLevel = min(max(normalized, 0.02), 1)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
