@preconcurrency import AVFoundation
import Foundation

// Owns permission checks, serial capture-session configuration, timing, and recorder callbacks.

@MainActor
final class LessonCameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var isSessionReady = false
    @Published var isRecording = false
    @Published var elapsedSeconds = 0
    @Published var audioLevel = 0.0
    @Published var errorMessage: String?
    @Published var lastRecordingURL: URL?
    @Published var lastRecordingDurationSeconds = 0

    private let sessionQueue = DispatchQueue(label: "resonance.lesson-camera.session")
    private let audioQueue = DispatchQueue(label: "resonance.lesson-camera.audio")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var startedAt: Date?
    private var timer: Timer?

    /// Requests camera and microphone access before configuring a usable recording session.
    func prepare() async {
        let hasVideo = await requestAccess(for: .video)
        let hasAudio = await requestAccess(for: .audio)
        guard hasVideo else {
            errorMessage = "Camera permission is required to film a teaching lesson."
            return
        }
        let didConfigure = await configureSession(includeAudio: hasAudio)
        isSessionReady = didConfigure
        errorMessage = didConfigure ? nil : "Camera is unavailable on this device."
    }

    func startRecording(to url: URL) {
        guard isSessionReady, !movieOutput.isRecording else { return }
        lastRecordingURL = nil
        lastRecordingDurationSeconds = 0
        elapsedSeconds = 0
        startedAt = Date()
        if let connection = movieOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        startTimer()
    }

    func stopRecording() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        stopTimer()
        isRecording = false
    }

    func stopSession() {
        stopTimer()
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func configureSession(includeAudio: Bool) async -> Bool {
        let session = session
        let movieOutput = movieOutput
        let audioOutput: AVCaptureAudioDataOutput?
        if includeAudio {
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: audioQueue)
            audioOutput = output
        } else {
            audioOutput = nil
        }

        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                session.beginConfiguration()
                session.sessionPreset = .high

                do {
                    guard
                        let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                            ?? AVCaptureDevice.default(for: .video)
                    else {
                        throw LessonCameraError.cameraUnavailable
                    }
                    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                    guard session.canAddInput(videoInput) else {
                        throw LessonCameraError.cameraUnavailable
                    }
                    session.addInput(videoInput)

                    if includeAudio,
                       let audioDevice = AVCaptureDevice.default(for: .audio),
                       let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                       session.canAddInput(audioInput) {
                        session.addInput(audioInput)
                    }

                    guard session.canAddOutput(movieOutput) else {
                        throw LessonCameraError.cameraUnavailable
                    }
                    session.addOutput(movieOutput)

                    if let audioOutput, session.canAddOutput(audioOutput) {
                        session.addOutput(audioOutput)
                    }

                    session.commitConfiguration()
                    session.startRunning()
                    continuation.resume(returning: true)
                } catch {
                    session.commitConfiguration()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(updateElapsedTime),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func updateElapsedTime() {
        guard let startedAt else { return }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt).rounded(.down)))
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        audioLevel = 0
    }
}

extension LessonCameraController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let duration = Int(CMTimeGetSeconds(output.recordedDuration).rounded())
        let errorMessage = error?.localizedDescription
        let outputPath = outputFileURL.path
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stopTimer()
            self.isRecording = false
            if let errorMessage {
                self.errorMessage = errorMessage
                FileStore.deleteFileIfExists(atPath: outputPath)
                return
            }
            FileStore.setFileProtection(url: outputFileURL)
            self.lastRecordingURL = outputFileURL
            self.lastRecordingDurationSeconds = max(self.elapsedSeconds, duration)
        }
    }
}

extension LessonCameraController: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let channel = connection.audioChannels.first else { return }
        let normalized = pow(10.0, Double(channel.averagePowerLevel) / 20.0)
        let level = min(max(normalized * 4.0, 0.02), 1.0)
        Task { @MainActor [weak self] in
            self?.audioLevel = level
        }
    }
}

enum LessonCameraError: Error {
    case cameraUnavailable
}
