import AVFoundation
import SwiftUI

struct CaptureMarkerDraft: Identifiable {
    let id: String
    let timeSeconds: Int
    let kind: CaptureMarkerKind
    let note: String?
}

struct TeachingLessonCaptureResult {
    let videoURL: URL
    let captureProfile: CaptureProfile
    let markers: [CaptureMarkerDraft]
    let durationSeconds: Int
}

struct TeachingLessonCameraView: View {
    let entryId: String
    let onComplete: (TeachingLessonCaptureResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = LessonCameraController()
    @State private var selectedProfile: CaptureProfile
    @State private var markers: [CaptureMarkerDraft] = []
    @State private var showSafeFrame = true
    @State private var showMovementCorridor = true
    @State private var showSubjectZones = true
    @State private var showNoConsentZone = true
    @State private var showStaticContours = true
    @State private var consentAndPlacementChecked = false

    private let quickMarkerKinds: [CaptureMarkerKind] = [
        .phaseSetup,
        .phaseModeling,
        .phaseGuidedPractice,
        .phaseStudentWork,
        .phaseFeedback,
        .phaseReflection,
        .momentQuestion,
        .momentMusicalModel,
        .momentStudentResponse,
        .momentTransition,
        .privacyNote,
    ]

    init(
        entryId: String,
        initialProfile: CaptureProfile? = nil,
        onComplete: @escaping (TeachingLessonCaptureResult) -> Void
    ) {
        self.entryId = entryId
        self.onComplete = onComplete
        _selectedProfile = State(initialValue: initialProfile ?? .teacherLearner)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                CameraPreview(session: camera.session)
                    .ignoresSafeArea()

                CaptureOverlayView(
                    profile: selectedProfile,
                    showSafeFrame: showSafeFrame,
                    showMovementCorridor: showMovementCorridor,
                    showSubjectZones: showSubjectZones,
                    showNoConsentZone: showNoConsentZone,
                    showStaticContours: showStaticContours
                )
                .allowsHitTesting(false)
                .ignoresSafeArea()

                if !camera.isSessionReady {
                    cameraUnavailableView
                }

                VStack(spacing: 0) {
                    topControls
                    Spacer()
                    bottomControls
                }
                .padding()
            }
            .navigationTitle("Film Lesson")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if camera.isRecording {
                            camera.stopRecording()
                        }
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
            .task {
                await camera.prepare()
            }
            .onDisappear {
                if camera.isRecording {
                    camera.stopRecording()
                }
                camera.stopSession()
            }
        }
    }

    private var topControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Camera profile", selection: $selectedProfile) {
                ForEach(CaptureProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)

            Toggle("Consent, landscape placement, and no-consent zone checked", isOn: $consentAndPlacementChecked)
                .toggleStyle(.switch)
                .tint(AppTheme.accentVibrant)

            HStack(spacing: 10) {
                overlayToggle("Safe", isOn: $showSafeFrame)
                overlayToggle("Path", isOn: $showMovementCorridor)
                overlayToggle("Zones", isOn: $showSubjectZones)
                overlayToggle("Privacy", isOn: $showNoConsentZone)
                overlayToggle("Contours", isOn: $showStaticContours)
            }
        }
        .font(.caption)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            HStack {
                Label(formatTime(camera.elapsedSeconds), systemImage: camera.isRecording ? "record.circle" : "video")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(camera.isRecording ? .red : .white)
                Spacer()
                AudioLevelMeter(level: camera.audioLevel)
                    .frame(width: 96, height: 10)
                    .accessibilityLabel("Audio level")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickMarkerKinds) { kind in
                        Button(kind.label) {
                            addMarker(kind)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(kind == .privacyNote ? .red.opacity(0.85) : .white.opacity(0.18))
                        .foregroundStyle(.white)
                        .disabled(!camera.isRecording)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    if camera.isRecording {
                        camera.stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    Label(
                        camera.isRecording ? "Stop" : "Record",
                        systemImage: camera.isRecording ? "stop.fill" : "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(camera.isRecording ? .red : AppTheme.accentVibrant)
                .disabled(!camera.isSessionReady || !consentAndPlacementChecked)

                Button("Use Video") {
                    guard let lastURL = camera.lastRecordingURL else { return }
                    onComplete(
                        TeachingLessonCaptureResult(
                            videoURL: lastURL,
                            captureProfile: selectedProfile,
                            markers: markers,
                            durationSeconds: max(camera.lastRecordingDurationSeconds, 0)
                        )
                    )
                    dismiss()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.white)
                .disabled(camera.lastRecordingURL == nil || camera.isRecording)
            }
        }
        .padding(12)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
    }

    private var cameraUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.largeTitle)
            Text(camera.errorMessage ?? "Camera unavailable")
                .font(.headline)
            Text("Import an existing lesson video from the entry screen.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .padding()
    }

    private func overlayToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
    }

    private func startRecording() {
        markers.removeAll()
        let destination = FileStore.createVideoFileURL(entryId: entryId)
        camera.startRecording(to: destination)
    }

    private func addMarker(_ kind: CaptureMarkerKind) {
        markers.append(
            CaptureMarkerDraft(
                id: UUID().uuidString,
                timeSeconds: camera.elapsedSeconds,
                kind: kind,
                note: nil
            )
        )
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("PreviewView must use AVCaptureVideoPreviewLayer")
        }
        return previewLayer
    }
}

private struct AudioLevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule()
                    .fill(level > 0.85 ? Color.red : AppTheme.accentVibrant)
                    .frame(width: max(4, proxy.size.width * min(max(level, 0), 1)))
            }
        }
    }
}

private struct CaptureOverlayView: View {
    let profile: CaptureProfile
    let showSafeFrame: Bool
    let showMovementCorridor: Bool
    let showSubjectZones: Bool
    let showNoConsentZone: Bool
    let showStaticContours: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                horizon(in: size)

                if showSafeFrame {
                    safeFrame(in: size)
                }
                if showMovementCorridor {
                    movementCorridor(in: size)
                }
                if showSubjectZones {
                    subjectZones(in: size)
                }
                if showNoConsentZone {
                    noConsentZone(in: size)
                }
                if showStaticContours {
                    staticContours(in: size)
                }
            }
        }
    }

    private func horizon(in size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height * 0.5))
            path.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
        }
        .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [8, 8]))
    }

    private func safeFrame(in size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [10, 7]))
            .frame(width: size.width * 0.86, height: size.height * 0.72)
    }

    private func movementCorridor(in size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(AppTheme.accentVibrant.opacity(0.75), lineWidth: 2)
            .background(AppTheme.accentVibrant.opacity(0.08))
            .frame(width: size.width * 0.22, height: size.height * 0.62)
            .position(x: size.width * 0.28, y: size.height * 0.56)
    }

    private func subjectZones(in size: CGSize) -> some View {
        ZStack {
            switch profile {
            case .roomOverview:
                zone(rect: CGRect(x: size.width * 0.16, y: size.height * 0.22, width: size.width * 0.68, height: size.height * 0.48), color: .cyan)
            case .teacherLearner:
                zone(rect: CGRect(x: size.width * 0.18, y: size.height * 0.26, width: size.width * 0.22, height: size.height * 0.5), color: .cyan)
                zone(rect: CGRect(x: size.width * 0.48, y: size.height * 0.28, width: size.width * 0.36, height: size.height * 0.42), color: .yellow)
            case .instrumentCloseup:
                zone(rect: CGRect(x: size.width * 0.28, y: size.height * 0.34, width: size.width * 0.44, height: size.height * 0.32), color: .orange)
            case .ensembleGroup:
                zone(rect: CGRect(x: size.width * 0.14, y: size.height * 0.36, width: size.width * 0.22, height: size.height * 0.32), color: .cyan)
                zone(rect: CGRect(x: size.width * 0.39, y: size.height * 0.30, width: size.width * 0.22, height: size.height * 0.38), color: .yellow)
                zone(rect: CGRect(x: size.width * 0.64, y: size.height * 0.36, width: size.width * 0.22, height: size.height * 0.32), color: .green)
            case .groupWork:
                zone(rect: CGRect(x: size.width * 0.12, y: size.height * 0.25, width: size.width * 0.32, height: size.height * 0.24), color: .cyan)
                zone(rect: CGRect(x: size.width * 0.56, y: size.height * 0.25, width: size.width * 0.32, height: size.height * 0.24), color: .yellow)
                zone(rect: CGRect(x: size.width * 0.12, y: size.height * 0.58, width: size.width * 0.32, height: size.height * 0.24), color: .green)
                zone(rect: CGRect(x: size.width * 0.56, y: size.height * 0.58, width: size.width * 0.32, height: size.height * 0.24), color: .orange)
            }
        }
    }

    private func noConsentZone(in size: CGSize) -> some View {
        ZStack {
            Rectangle()
                .fill(.red.opacity(0.12))
            Rectangle()
                .stroke(.red.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: size.width * 0.24, y: size.height * 0.22))
            }
            .stroke(.red.opacity(0.8), lineWidth: 2)
        }
        .frame(width: size.width * 0.24, height: size.height * 0.22)
        .position(x: size.width * 0.14, y: size.height * 0.16)
    }

    private func staticContours(in size: CGSize) -> some View {
        ZStack {
            personContour()
                .frame(width: size.width * 0.12, height: size.height * 0.28)
                .position(x: size.width * 0.28, y: size.height * 0.45)

            instrumentContour()
                .frame(width: size.width * 0.22, height: size.height * 0.16)
                .position(x: size.width * 0.62, y: size.height * 0.55)
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    private func zone(rect: CGRect, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(color.opacity(0.82), lineWidth: 2)
            .background(color.opacity(0.07))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func personContour() -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                Circle()
                    .stroke(lineWidth: 2)
                    .frame(width: width * 0.32, height: width * 0.32)
                    .position(x: width * 0.5, y: height * 0.15)
                RoundedRectangle(cornerRadius: width * 0.18)
                    .stroke(lineWidth: 2)
                    .frame(width: width * 0.48, height: height * 0.5)
                    .position(x: width * 0.5, y: height * 0.48)
                Path { path in
                    path.move(to: CGPoint(x: width * 0.5, y: height * 0.72))
                    path.addLine(to: CGPoint(x: width * 0.25, y: height * 0.98))
                    path.move(to: CGPoint(x: width * 0.5, y: height * 0.72))
                    path.addLine(to: CGPoint(x: width * 0.75, y: height * 0.98))
                }
                .stroke(lineWidth: 2)
            }
        }
    }

    private func instrumentContour() -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            Path { path in
                path.addRoundedRect(
                    in: CGRect(x: width * 0.05, y: height * 0.32, width: width * 0.55, height: height * 0.36),
                    cornerSize: CGSize(width: 16, height: 16)
                )
                path.move(to: CGPoint(x: width * 0.58, y: height * 0.5))
                path.addLine(to: CGPoint(x: width * 0.96, y: height * 0.34))
                path.move(to: CGPoint(x: width * 0.58, y: height * 0.5))
                path.addLine(to: CGPoint(x: width * 0.96, y: height * 0.66))
            }
            .stroke(lineWidth: 2)
        }
    }
}

private final class LessonCameraController: NSObject, ObservableObject {
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
    private var audioOutput: AVCaptureAudioDataOutput?
    private var startedAt: Date?
    private var timer: Timer?

    func prepare() async {
        let hasVideo = await requestAccess(for: .video)
        let hasAudio = await requestAccess(for: .audio)
        guard hasVideo else {
            await MainActor.run {
                errorMessage = "Camera permission is required to film a teaching lesson."
            }
            return
        }
        configureSession(includeAudio: hasAudio)
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

    private func configureSession(includeAudio: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            do {
                guard
                    let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                        ?? AVCaptureDevice.default(for: .video)
                else {
                    throw LessonCameraError.cameraUnavailable
                }
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                guard self.session.canAddInput(videoInput) else {
                    throw LessonCameraError.cameraUnavailable
                }
                self.session.addInput(videoInput)

                if includeAudio,
                   let audioDevice = AVCaptureDevice.default(for: .audio),
                   let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                   self.session.canAddInput(audioInput) {
                    self.session.addInput(audioInput)
                }

                guard self.session.canAddOutput(self.movieOutput) else {
                    throw LessonCameraError.cameraUnavailable
                }
                self.session.addOutput(self.movieOutput)

                if includeAudio {
                    let audioOutput = AVCaptureAudioDataOutput()
                    audioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)
                    if self.session.canAddOutput(audioOutput) {
                        self.session.addOutput(audioOutput)
                        self.audioOutput = audioOutput
                    }
                }

                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isSessionReady = true
                    self.errorMessage = nil
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.errorMessage = "Camera is unavailable on this device."
                    self.isSessionReady = false
                }
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt).rounded(.down)))
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        audioLevel = 0
    }
}

extension LessonCameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.stopTimer()
            self.isRecording = false
            if let error {
                self.errorMessage = error.localizedDescription
                FileStore.deleteFileIfExists(atPath: outputFileURL.path)
                return
            }
            FileStore.setFileProtection(url: outputFileURL)
            self.lastRecordingURL = outputFileURL
            self.lastRecordingDurationSeconds = max(
                self.elapsedSeconds,
                Int(CMTimeGetSeconds(output.recordedDuration).rounded())
            )
        }
    }
}

extension LessonCameraController: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let channel = connection.audioChannels.first else { return }
        let normalized = pow(10.0, Double(channel.averagePowerLevel) / 20.0)
        DispatchQueue.main.async {
            self.audioLevel = min(max(normalized * 4.0, 0.02), 1.0)
        }
    }
}

private enum LessonCameraError: Error {
    case cameraUnavailable
}
