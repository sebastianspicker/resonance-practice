@preconcurrency import AVFoundation
import SwiftUI

// Supplies the live camera preview, audio meter, and privacy-aware lesson-capture overlays.

struct CameraPreview: UIViewRepresentable {
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

final class PreviewView: UIView {
    override static var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("PreviewView must use AVCaptureVideoPreviewLayer")
        }
        return previewLayer
    }
}

struct AudioLevelMeter: View {
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

/// Draws framing and consent guidance only; it performs no detection or enforcement.
struct CaptureOverlayView: View {
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
                zone(
                    rect: CGRect(x: size.width * 0.16, y: size.height * 0.22, width: size.width * 0.68, height: size.height * 0.48),
                    color: .cyan
                )
            case .teacherLearner:
                zone(
                    rect: CGRect(x: size.width * 0.18, y: size.height * 0.26, width: size.width * 0.22, height: size.height * 0.5),
                    color: .cyan
                )
                zone(
                    rect: CGRect(x: size.width * 0.48, y: size.height * 0.28, width: size.width * 0.36, height: size.height * 0.42),
                    color: .yellow
                )
            case .instrumentCloseup:
                zone(
                    rect: CGRect(x: size.width * 0.28, y: size.height * 0.34, width: size.width * 0.44, height: size.height * 0.32),
                    color: .orange
                )
            case .ensembleGroup:
                zone(
                    rect: CGRect(x: size.width * 0.14, y: size.height * 0.36, width: size.width * 0.22, height: size.height * 0.32),
                    color: .cyan
                )
                zone(
                    rect: CGRect(x: size.width * 0.39, y: size.height * 0.30, width: size.width * 0.22, height: size.height * 0.38),
                    color: .yellow
                )
                zone(
                    rect: CGRect(x: size.width * 0.64, y: size.height * 0.36, width: size.width * 0.22, height: size.height * 0.32),
                    color: .green
                )
            case .groupWork:
                zone(
                    rect: CGRect(x: size.width * 0.12, y: size.height * 0.25, width: size.width * 0.32, height: size.height * 0.24),
                    color: .cyan
                )
                zone(
                    rect: CGRect(x: size.width * 0.56, y: size.height * 0.25, width: size.width * 0.32, height: size.height * 0.24),
                    color: .yellow
                )
                zone(
                    rect: CGRect(x: size.width * 0.12, y: size.height * 0.58, width: size.width * 0.32, height: size.height * 0.24),
                    color: .green
                )
                zone(
                    rect: CGRect(x: size.width * 0.56, y: size.height * 0.58, width: size.width * 0.32, height: size.height * 0.24),
                    color: .orange
                )
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
