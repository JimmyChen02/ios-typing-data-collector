import SwiftUI
import AVFoundation

// MARK: - LivePostureDemoView
//
// Standalone live-classification demo screen, reachable from
// ParticipantSetupView — fully separate from the study and posture-training
// flows (no session, no logging, nothing persisted).
//
// Shows a full-screen front-camera feed with the live IMU posture
// prediction overlaid. The camera feed is DISPLAY-ONLY: the posture label
// is predicted from motion alone (D3, IMU-only Core ML model); the feed
// exists so the demo video shows the user AND the label tracking their
// grip at the same time.
//
// Motion comes from MotionRecorder.startMonitoring() (live fan-out only —
// no CSV, no buffering), so running this screen never creates session data.

struct LivePostureDemoView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var camera = LiveDemoCameraController()
    @State private var cameraUnavailable = false

    private var predictor: PosturePredictor { PosturePredictor.shared }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if cameraUnavailable {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.6))
                    Text("Camera unavailable\n(Simulator or permission denied)")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                }
            } else {
                LiveDemoPreviewView(session: camera.session)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.85))
                            .shadow(radius: 3)
                    }
                    .padding(.trailing, 20)
                }
                Spacer()
                predictionCard
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            camera.onUnavailable = { cameraUnavailable = true }
            camera.start()
            MotionRecorder.shared.startMonitoring()
            predictor.start()
        }
        .onDisappear {
            predictor.stop()
            MotionRecorder.shared.stopMonitoring()
            camera.stop()
        }
    }

    // MARK: - Prediction card

    private var predictionCard: some View {
        VStack(spacing: 8) {
            if predictor.isModelAvailable {
                let hand = predictor.livePredictedPosture
                HStack(spacing: 8) {
                    Circle().fill(tagColor(for: hand)).frame(width: 10, height: 10)
                    Text(hand == .unknown ? "Detecting\u{2026}" : hand.displayName)
                        .font(.title3).fontWeight(.bold)
                    if hand != .unknown {
                        Text(String(format: "%.0f%%", predictor.confidence * 100))
                            .font(.title3).foregroundColor(.secondary)
                    }
                }
                Text("Predicted from motion only — hold the phone left / right / both hands and move as if typing")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("No Core ML model bundled")
                        .fontWeight(.semibold)
                }
                Text("Export + bundle posture_imu.mlpackage first (docs/POSTURE_DEMO.md)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .padding(.horizontal, 24)
    }

    private func tagColor(for hand: HoldingHand) -> Color {
        switch hand {
        case .left:    return .blue
        case .right:   return .green
        case .both:    return .orange
        case .unknown: return .gray
        }
    }
}

// MARK: - LiveDemoCameraController
//
// Owns a dedicated AVCaptureSession for the demo screen (safe: the demo is
// never on-screen at the same time as HandBurstCapture's session, which
// only runs inside typing sessions). Preview-only — no video data output,
// no frames processed or saved.

@MainActor
final class LiveDemoCameraController {

    let session = AVCaptureSession()

    var onUnavailable: (() -> Void)?

    private let sessionQueue = DispatchQueue(label: "LiveDemoCamera.session", qos: .userInitiated)
    private var isConfigured = false

    func start() {
        guard !isConfigured else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted { self?.configureAndStart() } else { self?.onUnavailable?() }
                }
            }
        default:
            onUnavailable?()
        }
    }

    func stop() {
        let s = session
        sessionQueue.async { s.stopRunning() }
    }

    private func configureAndStart() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            onUnavailable?()
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            onUnavailable?()
            return
        }
        session.addInput(input)
        session.commitConfiguration()

        isConfigured = true
        let s = session
        sessionQueue.async { s.startRunning() }
    }
}

// MARK: - LiveDemoPreviewView
//
// Full-screen AVCaptureVideoPreviewLayer (aspect-fill).

struct LiveDemoPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        PreviewUIView(session: session)
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        private let previewLayer: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            previewLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }
}
