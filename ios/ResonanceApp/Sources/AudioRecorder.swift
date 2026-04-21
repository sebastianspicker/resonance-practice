import Foundation
import AVFoundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "AudioRecorder")

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording: Bool = false
    @Published var duration: TimeInterval = 0

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
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        lastURL = url
        recorder?.record()
        isRecording = true
        startTimer()
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
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
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.duration = self.recorder?.currentTime ?? 0
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
