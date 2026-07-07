import SwiftUI

// MARK: - CameraPreviewOverlay
//
// D2c — a small toggle button on the typing screen (during a posture
// training run) that shows a floating picture-in-picture camera preview
// with a predicted-posture "tag".
//
// Requirements from the spec:
//   - Reuses the existing HandBurstCapture frame stream (via
//     SessionManager.latestPostureFrame / PostureCaptureController) instead
//     of starting a second AVCaptureSession — two AVCaptureSessions on the
//     same device may conflict.
//   - Must NOT steal keyboard focus, pause the typing session/timer, or
//     hinder typing in any way — rendered as a compact floating card in the
//     empty region above the keyboard (never over the keys or target text),
//     with hit-testing disabled so every touch passes straight through to
//     the views underneath. Dismissal is only via the toggle button.
//   - The tag shows livePredictedPosture (D3) when a Core ML model is
//     available; otherwise falls back to the user-selected posture with a
//     "(declared)" suffix, so the UI is testable before the model exists.

struct PostureCameraToggleButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            Image(systemName: isPresented ? "camera.viewfinder" : "camera")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(8)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .accessibilityLabel("Toggle posture camera preview")
    }
}

struct CameraPreviewOverlay: View {
    var sessionManager: SessionManager

    // Poll for the latest frame + predicted posture on a lightweight timer
    // rather than a stronger observation dependency, so this overlay stays
    // decoupled from SessionManager's own @Observable change ticks (which
    // fire far more often, e.g. once per keystroke).
    @State private var refreshTimer: Timer?
    @State private var frameTick: Int = 0

    private var posturePredictor: PosturePredictor { PosturePredictor.shared }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))

                if let image = sessionManager.latestPostureFrame {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 110, height: 146)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.metering.unknown")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("Waiting\u{2026}")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 110, height: 146)

            tagView
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemGray6).opacity(0.95)))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        // Touches pass through the card — typing can never be blocked by it.
        .allowsHitTesting(false)
        .onAppear {
            posturePredictor.start()
            startRefreshTimer()
        }
        .onDisappear {
            posturePredictor.stop()
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Tag

    private var tagView: some View {
        Group {
            if posturePredictor.isModelAvailable {
                // D3 present: show the live prediction + confidence.
                let hand = posturePredictor.livePredictedPosture
                HStack(spacing: 5) {
                    Circle().fill(tagColor(for: hand)).frame(width: 7, height: 7)
                    Text(hand.displayName)
                        .fontWeight(.semibold)
                    Text(String(format: "%.0f%%", posturePredictor.confidence * 100))
                        .foregroundColor(.secondary)
                }
            } else {
                // Staged D2/D3 handoff: no Core ML model shipped yet, so the
                // tag shows the DECLARED posture with a "(declared)" suffix.
                // This lets the D2c UI be tested end-to-end before D3 lands.
                let hand = sessionManager.selectedPosture
                HStack(spacing: 5) {
                    Circle().fill(tagColor(for: hand)).frame(width: 7, height: 7)
                    Text("\(hand.displayName) (declared)")
                        .fontWeight(.semibold)
                }
            }
        }
        .font(.caption)
        .foregroundColor(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(.systemGray5)))
    }

    private func tagColor(for hand: HoldingHand) -> Color {
        switch hand {
        case .left:    return .blue
        case .right:   return .green
        case .both:    return .orange
        case .unknown: return .gray
        }
    }

    // MARK: - Refresh

    /// SwiftUI does not automatically re-render from PosturePredictor's
    /// @Observable state changing on a background-originated timer tick in
    /// all cases (the mutations happen inside Task { @MainActor } hops); a
    /// cheap periodic no-op state write guarantees the tag/image stay live
    /// at the same ~2 Hz cadence PosturePredictor predicts at.
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                frameTick &+= 1
            }
        }
    }
}
