import SwiftUI
import SwiftData
import UIKit

// MARK: - HandCaptureView
//
// Presented as a .sheet at the BetweenSessionView boundary.
//
// Walks the participant through a guided 3-condition burst:
//   left hand → right hand → both hands
//
// For each condition a HandBurstCapture burst runs for `captureSeconds`
// seconds at ~2 Hz, saving one JPEG + one HandSample row per frame.
//
// The onComplete callback receives the full [HandSample] array (all
// conditions), or nil if the user skips / the camera is unavailable.
//
// Init params (unchanged from the single-still version):
//   participant         — used for device metadata
//   sessionId           — nil if captured outside a session
//   studyId             — written to each HandSample
//   studySessionIndex   — unused here; per-frame index written instead
//   onComplete          — ([HandSample]?) -> Void; nil = skipped

// MARK: - Tunable constants (one-line changes to adjust duration / rate)
private let captureSeconds: Int  = 30    // seconds per condition (~60 frames @ 2Hz)
private let targetFPS:      Double = 2.0 // frames per second (~60 frames / condition)

struct HandCaptureView: View {
    @Environment(\.modelContext) private var modelContext

    let participant: Participant
    let sessionId: UUID?
    let studyId: UUID
    let studySessionIndex: Int          // passed in but unused; per-frame index used instead
    let onComplete: ([HandSample]?) -> Void

    // MARK: - Phase state machine

    private enum Phase: Equatable {
        case intro
        case paused(HoldingHand)     // pause between conditions, waiting for user to tap Start
        case capturing(HoldingHand)
        case reviewing
        case done
    }

    @State private var phase: Phase = .intro

    // Frames collected across all conditions
    @State private var collected: [HandSample] = []

    // Per-condition frame counter (resets to 0 at the start of each condition)
    @State private var frameIndex: Int = 0

    // Capture engine
    @State private var capture = HandBurstCapture()

    // Countdown timer state
    @State private var secondsRemaining: Int = captureSeconds
    @State private var countdownTask: Task<Void, Never>? = nil

    // Camera unavailable flag
    @State private var cameraUnavailable: Bool = false

    // Per-condition frame counts (for the reviewing screen)
    @State private var leftCount:  Int = 0
    @State private var rightCount: Int = 0
    @State private var bothCount:  Int = 0

    // MARK: - Init

    init(
        participant: Participant,
        sessionId: UUID?,
        studyId: UUID,
        studySessionIndex: Int,
        onComplete: @escaping ([HandSample]?) -> Void
    ) {
        self.participant = participant
        self.sessionId = sessionId
        self.studyId = studyId
        self.studySessionIndex = studySessionIndex
        self.onComplete = onComplete
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .intro:
                    introView
                case .paused(let hand):
                    pausedView(hand: hand)
                case .capturing(let hand):
                    capturingView(hand: hand)
                        .id(hand)
                case .reviewing:
                    reviewingView
                case .done:
                    // Transient; onComplete fires immediately on transition
                    ProgressView()
                }
            }
            .navigationTitle("Holding Hand Capture")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onDisappear {
            // Sheet dismissed early (home button, swipe down) — stop capture,
            // discard partial data (spec: keep nothing on early dismiss).
            if phase != .done {
                capture.stop()
                countdownTask?.cancel()
            }
        }
    }

    // MARK: - Intro screen

    private var introView: some View {
        Form {
            Section {
                Text("Hold the phone naturally, as you would while typing. The app will capture ~\(captureSeconds) seconds of front-camera frames for each holding-hand condition (left, right, both hands).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("You will be guided through three conditions back-to-back. Each condition takes about \(captureSeconds) seconds.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Section("Conditions") {
                Label("Left hand",  systemImage: "hand.point.left.fill").foregroundColor(.orange)
                Label("Right hand", systemImage: "hand.point.right.fill").foregroundColor(.orange)
                Label("Both hands", systemImage: "hands.clap.fill").foregroundColor(.orange)
            }

            Section {
                Button(action: { pauseBeforeCondition(.left) }) {
                    HStack {
                        Spacer()
                        Text("Start Capture")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.vertical, 8)
                        Spacer()
                    }
                }
                .listRowBackground(Color.orange)

                Button(action: skip) {
                    HStack {
                        Spacer()
                        Text("Skip")
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                        Spacer()
                    }
                }
                .listRowBackground(Color(.systemGray6))
            }
        }
    }

    // MARK: - Paused screen (between conditions)

    private func pausedView(hand: HoldingHand) -> some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Text("Hold the phone with your")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Text(hand.displayName.uppercased())
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(ringColor(for: hand))
            }

            Spacer()

            Button(action: { startCondition(hand) }) {
                HStack {
                    Spacer()
                    Text("Start")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.vertical, 12)
                    Spacer()
                }
            }
            .background(Color(ringColor(for: hand)))
            .cornerRadius(14)
            .padding(.horizontal, 24)
        }
        .padding()
    }

    // MARK: - Capturing screen

    private func capturingView(hand: HoldingHand) -> some View {
        VStack(spacing: 32) {
            Spacer()

            // Which hand label
            VStack(spacing: 12) {
                Text("Hold the phone with your")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Text(hand.displayName.uppercased())
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
            }

            // Look-at-screen prompt: the front camera needs the participant's
            // upper body / face in frame for HandyTrak segmentation.
            if !cameraUnavailable {
                Label("Look at the screen and keep your face and shoulders in view", systemImage: "eyes")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Progress ring / countdown
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 12)
                    .frame(width: 140, height: 140)

                Circle()
                    .trim(from: 0, to: captureProgress)
                    .stroke(ringColor(for: hand), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: secondsRemaining)

                // Center: show remaining seconds during capture; swap to a
                // checkmark when secondsRemaining hits 0 (ring full). The
                // checkmark shows during the brief transition before
                // finishCondition auto-advances — no sleep or delay added.
                if secondsRemaining == 0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(ringColor(for: hand))
                } else {
                    VStack(spacing: 4) {
                        Text("\(secondsRemaining)")
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                        Text("seconds")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Frame counter
            VStack(spacing: 4) {
                Text("\(frameIndex)")
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange)
                Text("frames captured")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Camera unavailable path
            if cameraUnavailable {
                VStack(spacing: 12) {
                    Text("Camera unavailable")
                        .font(.headline)
                        .foregroundColor(.red)
                    Text("The front camera could not be accessed. You can skip this step.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button(action: skip) {
                        Text("Skip")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray5))
                            .foregroundColor(.primary)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 32)
                }
            }

            Spacer()
        }
        .padding()
        .onAppear {
            beginCapture(for: hand)
        }
    }

    // MARK: - Reviewing screen

    private var reviewingView: some View {
        Form {
            Section("Frames Captured") {
                HStack {
                    Label("Left hand",  systemImage: "hand.point.left.fill")
                    Spacer()
                    Text("\(leftCount) frames").foregroundColor(.secondary)
                }
                HStack {
                    Label("Right hand", systemImage: "hand.point.right.fill")
                    Spacer()
                    Text("\(rightCount) frames").foregroundColor(.secondary)
                }
                HStack {
                    Label("Both hands", systemImage: "hands.clap.fill")
                    Spacer()
                    Text("\(bothCount) frames").foregroundColor(.secondary)
                }
                HStack {
                    Text("Total").fontWeight(.semibold)
                    Spacer()
                    Text("\(collected.count) frames").fontWeight(.semibold)
                }
            }

            Section {
                Button(action: { onComplete(collected) }) {
                    HStack {
                        Spacer()
                        Text("Save & Continue")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.vertical, 8)
                        Spacer()
                    }
                }
                .listRowBackground(Color.orange)

                Button(action: skip) {
                    HStack {
                        Spacer()
                        Text("Discard")
                            .foregroundColor(.red)
                            .padding(.vertical, 4)
                        Spacer()
                    }
                }
                .listRowBackground(Color(.systemGray6))
            }
        }
        .navigationTitle("Review Capture")
    }

    // MARK: - Capture logic

    private func pauseBeforeCondition(_ hand: HoldingHand) {
        phase = .paused(hand)
    }

    private func startCondition(_ hand: HoldingHand) {
        capture.stop()              // stop previous condition's engine deterministically
        countdownTask?.cancel()     // cancel previous countdown
        frameIndex = 0
        secondsRemaining = captureSeconds
        cameraUnavailable = false
        phase = .capturing(hand)
    }

    private func beginCapture(for hand: HoldingHand) {
        capture = HandBurstCapture()
        capture.targetFPS = targetFPS

        // Closures that mutate @State must do so via the captured @State
        // projected-value bindings, not via a struct-value capture of `self`.
        // We reference the specific @State wrappers so mutations flow back
        // into SwiftUI's state graph.
        capture.onUnavailable = {
            // Already on main actor (HandBurstCapture is @MainActor).
            // Mark unavailable and cancel the countdown; the UI shows Skip.
            cameraUnavailable = true
            countdownTask?.cancel()
            // capture.stop() is safe here: HandBurstCapture.stop() is idempotent
            // and @MainActor, same actor as this closure.
            capture.stop()
        }

        // Pass the hand label through so the closure doesn't capture `self`
        // by value in a way that loses @State mutation.
        let capturedHand = hand
        capture.onFrame = { image in
            saveFrame(image, capturedHand)
        }

        capture.start()

        // Countdown timer using async/await
        countdownTask?.cancel()
        countdownTask = Task {
            for remaining in stride(from: captureSeconds - 1, through: 0, by: -1) {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return  // task cancelled
                }
                guard !Task.isCancelled else { return }
                secondsRemaining = remaining
            }
            // Countdown complete (secondsRemaining == 0, ring full). End the
            // capture window now so the pause below adds zero frames, then hold
            // briefly so SwiftUI renders the checkmark before auto-advancing.
            capture.stop()
            do {
                try await Task.sleep(nanoseconds: 400_000_000)  // ~0.4s: let the checkmark show
            } catch {
                return  // task cancelled during the hold
            }
            guard !Task.isCancelled else { return }
            finishCondition(hand)
        }
    }

    private func finishCondition(_ hand: HoldingHand) {
        capture.stop()
        countdownTask?.cancel()

        // Record per-condition counts for the reviewing screen
        switch hand {
        case .left:  leftCount  = frameIndex
        case .right: rightCount = frameIndex
        case .both:  bothCount  = frameIndex
        case .unknown: break
        }

        // Pause before next condition or go to reviewing
        switch hand {
        case .left:
            pauseBeforeCondition(.right)
        case .right:
            pauseBeforeCondition(.both)
        case .both, .unknown:
            phase = .reviewing
        }
    }

    // MARK: - Frame saving

    /// Saves one JPEG + inserts one HandSample row. Reuses HandImageStore.
    /// If saveImage returns nil (disk failure) a label-only row is still saved.
    private func saveFrame(_ image: UIImage, _ hand: HoldingHand) {
        let id = UUID()
        var rel = ""
        var w   = 0
        var h   = 0

        if let result = HandImageStore.shared.saveImage(image, id: id) {
            rel = result.relativePath
            w   = result.pixelWidth
            h   = result.pixelHeight
        }
        // Label-only row is valid even when saveImage fails — no crash.

        let sample = HandSample(
            participantId: participant.id,
            sessionId: sessionId,
            studyId: studyId,
            // studySessionIndex = per-frame counter (0,1,2,…) reset each
            // condition. This gives the Python trainer a strictly-increasing,
            // tie-free primary sort key within each (participant, label) block.
            studySessionIndex: frameIndex,
            capturedAt: Date(),
            holdingHand: hand,
            imageRelativePath: rel,
            imuRelativePath: sessionId.map { "imu/\($0.uuidString).csv" } ?? "",
            imagePixelWidth: w,
            imagePixelHeight: h,
            cameraPosition: "front",
            deviceModel: participant.deviceModel,
            systemVersion: participant.systemVersion,
            notes: ""
        )
        modelContext.insert(sample)
        collected.append(sample)
        frameIndex += 1
    }

    // MARK: - Ring helpers

    /// 0...1 fill fraction for the capture ring, derived from the real countdown
    /// so it cannot drift from actual capture timing. Resets to 0 each condition
    /// because secondsRemaining is reset to captureSeconds in startCondition.
    private var captureProgress: CGFloat {
        let total = CGFloat(captureSeconds)
        guard total > 0 else { return 0 }
        let elapsed = total - CGFloat(secondsRemaining)
        return min(max(elapsed / total, 0), 1)
    }

    /// Distinct ring color per holding-hand condition so the active hand is
    /// visually obvious. Left = blue, right = green, both = orange (app accent).
    private func ringColor(for hand: HoldingHand) -> Color {
        switch hand {
        case .left:    return .blue
        case .right:   return .green
        case .both:    return .orange
        case .unknown: return .orange
        }
    }

    // MARK: - Skip

    private func skip() {
        capture.stop()
        countdownTask?.cancel()
        onComplete(nil)
    }
}
