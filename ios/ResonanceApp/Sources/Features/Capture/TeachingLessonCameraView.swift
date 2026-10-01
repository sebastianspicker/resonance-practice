import SwiftUI

// Runs consent-gated teaching-lesson capture and returns its video, profile, markers, and duration.

/// Requires an explicit consent-and-placement check before enabling lesson recording.
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
        .privacyNote
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
                .padding(AppTheme.Spacing.standard)
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

    // MARK: - Top chrome (Atelier)

    private var topControls: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            HStack(spacing: AppTheme.Spacing.small) {
                Spacer(minLength: 0)
                consentChip
                Spacer(minLength: 0)
                profileMenuChip
                recordingTimerChip
            }

            HStack(spacing: AppTheme.Spacing.small) {
                overlayToggle("Safe", isOn: $showSafeFrame)
                overlayToggle("Path", isOn: $showMovementCorridor)
                overlayToggle("Zones", isOn: $showSubjectZones)
                overlayToggle("Privacy", isOn: $showNoConsentZone)
                overlayToggle("Contours", isOn: $showStaticContours)
                Spacer(minLength: 0)
                AudioLevelMeter(level: camera.audioLevel)
                    .frame(width: 72, height: 8)
                    .accessibilityLabel("Audio level")
            }
        }
        .font(.caption)
        .padding(AppTheme.Spacing.medium)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .foregroundStyle(.white)
    }

    /// Filled accent chip when consent is checked; outline chip toggles consent when unchecked.
    private var consentChip: some View {
        Button {
            consentAndPlacementChecked.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(consentAndPlacementChecked ? Color.white : AppTheme.accent)
                    .frame(width: 6, height: 6)
                Text("Private course review")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                if consentAndPlacementChecked {
                    Capsule(style: .continuous)
                        .fill(AppTheme.accent.opacity(0.92))
                } else {
                    Capsule(style: .continuous)
                        .strokeBorder(AppTheme.accent.opacity(0.75), lineWidth: 1)
                }
            }
            .foregroundStyle(consentAndPlacementChecked ? Color.white : AppTheme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Private course review consent")
        .accessibilityValue(consentAndPlacementChecked ? "Checked" : "Not checked")
        .accessibilityHint("Confirms consent, landscape placement, and no-consent zone before recording")
    }

    private var profileMenuChip: some View {
        Menu {
            Picker("Camera profile", selection: $selectedProfile) {
                ForEach(CaptureProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
        } label: {
            Text("Profile · \(selectedProfile.label)")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.white.opacity(0.14), in: Capsule(style: .continuous))
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Camera profile")
        .accessibilityValue(selectedProfile.label)
    }

    private var recordingTimerChip: some View {
        HStack(spacing: 6) {
            if camera.isRecording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
            }
            Text(formatTime(camera.elapsedSeconds))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(camera.isRecording ? Color.red : Color.white.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.35), in: Capsule(style: .continuous))
        .accessibilityLabel(camera.isRecording ? "Recording time" : "Elapsed time")
        .accessibilityValue(formatTime(camera.elapsedSeconds))
    }

    // MARK: - Bottom chrome

    private var bottomControls: some View {
        VStack(spacing: AppTheme.Spacing.medium) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.small) {
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

            HStack(spacing: AppTheme.Spacing.medium) {
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
                .tint(camera.isRecording ? .red : AppTheme.accent)
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
        .padding(AppTheme.Spacing.medium)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
    }

    private var cameraUnavailableView: some View {
        VStack(spacing: AppTheme.Spacing.medium) {
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
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
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
