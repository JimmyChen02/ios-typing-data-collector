import Foundation
import Observation
import CoreML

// MARK: - PosturePredictor
//
// D3 — loads the bundled IMU-only Core ML posture model (exported by
// scripts/export_imu_coreml.py from the D1 `--imu-seq --imu-causal` model),
// buffers the last `window` IMU samples from the live 50 Hz MotionRecorder
// stream via its onFrame hook, and runs prediction on a 30 Hz timer.
// Publishes `livePredictedPosture: HoldingHand` + `confidence`, smoothed by
// a majority vote over the last `voteWindowSize` raw predictions.
//
// Resolves OPEN QUESTION 1 = (A): IMU-only inference, no camera needed. The
// camera preview in D2c is display-only; this predictor never touches image
// frames.
//
// Must be a no-op (predictions stay .unknown) when the model resource is
// absent from the app bundle, so the app builds and runs before a model is
// shipped — this is the expected state until a researcher runs the D3
// export + reinstall recipe in docs/POSTURE_DEMO.md.
//
// Model resource name/window are tunable constants below; update them to
// match whatever `--out` name is used with export_imu_coreml.py.

@MainActor
@Observable
final class PosturePredictor {

    static let shared = PosturePredictor()

    // MARK: - Tunable constants

    /// Expected bundle resource name (without extension) for the exported
    /// Core ML model. export_imu_coreml.py's --out should produce a file
    /// with this name (e.g. `posture_imu.mlpackage` / `.mlmodelc`) added to
    /// the Xcode target's Copy Bundle Resources phase.
    static let modelResourceName = "posture_imu"

    /// Causal-trailing window size in IMU samples — MUST match the
    /// `--imu-window` value the bundled model was trained/exported with
    /// (default 50, ~1.0s at 50 Hz). See scripts/imu_sequence.py.
    static let windowSize = 50

    /// Number of raw channels per sample (excludes t_ms) — mirrors
    /// imu_sequence.IMU_CHANNELS / train_hand_classifier._IMU_CHANNELS.
    static let channelCount = 12

    /// Prediction cadence. Raised from the original ~3 Hz (D2c tag cadence)
    /// to 30 Hz so vote smoothing costs little wall-clock latency; the
    /// Conv1D is small enough that per-tick inference is sub-millisecond.
    private static let predictionInterval: TimeInterval = 1.0 / 30.0

    /// Majority-vote smoothing width: the published posture is the majority
    /// of the last `voteWindowSize` raw predictions (ties keep the previous
    /// published label). Tuned at THIS 30 Hz cadence by
    /// scripts/dense_window_sweep.py (2026-07-17): cross-user accuracy is
    /// flat in w (consecutive windows overlap ~96%, votes are correlated),
    /// but label stability keeps improving — 45 (1.5 s of votes, ~2.3
    /// switches/min vs 7.1 at w=1) was the steadiest and most accurate
    /// window that still follows a grip change within the ~1–2 s target
    /// (majority flips ~0.75 s after a clean transition). The old w=3 came
    /// from scripts/window_sweep.py at the retired ~2 Hz cadence and does
    /// not transfer.
    private static let voteWindowSize = 45

    // MARK: - Published state

    private(set) var livePredictedPosture: HoldingHand = .unknown
    private(set) var confidence: Double = 0.0

    /// True once a Core ML model was successfully loaded from the bundle.
    /// D2c uses this to decide whether to show the live tag or the
    /// "(declared)" placeholder.
    private(set) var isModelAvailable: Bool = false

    // MARK: - Private state

    private var model: MLModel?
    // Rolling buffer of the most recent MotionRecorder.MotionFrame values,
    // channel order matching imu_sequence.IMU_CHANNELS exactly:
    // [attitude_roll, attitude_pitch, attitude_yaw, grav_x, grav_y, grav_z,
    //  acc_x, acc_y, acc_z, rot_x, rot_y, rot_z]
    private var buffer: [[Double]] = []
    private var predictionTimer: Timer?
    private var isRunning: Bool = false

    // Raw per-tick predictions feeding the majority vote (most recent last;
    // at most `voteWindowSize` entries).
    private var recentPredictions: [HoldingHand] = []
    // Latest raw confidence seen per label, so the published confidence
    // always describes the published (voted) label rather than whatever the
    // newest raw tick predicted.
    private var latestConfidence: [HoldingHand: Double] = [:]

    private init() {
        loadModel()
    }

    // MARK: - Public API

    /// Starts buffering live IMU frames (via MotionRecorder.onFrame) and
    /// running predictions on a timer. No-op when isModelAvailable == false
    /// (predictions stay .unknown) or when already running (idempotent).
    /// Guarded so it is safe to call unconditionally from D2c — callers do
    /// not need to check isModelAvailable themselves.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        buffer.removeAll(keepingCapacity: true)

        guard isModelAvailable else { return }

        // Fan out from the SAME MotionRecorder that already backs CSV
        // recording — avoids a second CMMotionManager (per the D3 spec).
        // `onFrame` fires on MotionRecorder's delegate queue, not main;
        // hop to the main actor before touching `buffer` (a MainActor-
        // isolated property here).
        MotionRecorder.shared.onFrame = { [weak self] frame in
            Task { @MainActor in
                self?.appendFrame(frame)
            }
        }

        predictionTimer?.invalidate()
        predictionTimer = Timer.scheduledTimer(withTimeInterval: Self.predictionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runPrediction()
            }
        }
    }

    /// Stops buffering and prediction. Idempotent. Resets the published
    /// prediction back to .unknown so a stale tag is never shown after
    /// stopping.
    func stop() {
        isRunning = false
        predictionTimer?.invalidate()
        predictionTimer = nil
        if MotionRecorder.shared.onFrame != nil {
            MotionRecorder.shared.onFrame = nil
        }
        buffer.removeAll(keepingCapacity: true)
        recentPredictions.removeAll(keepingCapacity: true)
        latestConfidence.removeAll(keepingCapacity: true)
        livePredictedPosture = .unknown
        confidence = 0.0
    }

    // MARK: - Model loading

    private func loadModel() {
        // Look for a compiled model (.mlmodelc, produced by Xcode from a
        // bundled .mlpackage/.mlmodel) or a raw .mlpackage in the bundle.
        // Absent in normal development until the D3 export + reinstall
        // recipe (docs/POSTURE_DEMO.md) has been run — this is expected and
        // must not crash or block the app.
        let candidates = [
            Bundle.main.url(forResource: Self.modelResourceName, withExtension: "mlmodelc"),
            Bundle.main.url(forResource: Self.modelResourceName, withExtension: "mlpackage"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            isModelAvailable = false
            return
        }

        do {
            model = try MLModel(contentsOf: url)
            isModelAvailable = true
        } catch {
            print("PosturePredictor: failed to load Core ML model at \(url): \(error)")
            model = nil
            isModelAvailable = false
        }
    }

    // MARK: - Buffering

    private func appendFrame(_ frame: MotionRecorder.MotionFrame) {
        // Channel order MUST match imu_sequence.IMU_CHANNELS exactly.
        let row: [Double] = [
            frame.roll, frame.pitch, frame.yaw,
            frame.gravX, frame.gravY, frame.gravZ,
            frame.accX, frame.accY, frame.accZ,
            frame.rotX, frame.rotY, frame.rotZ,
        ]
        buffer.append(row)
        if buffer.count > Self.windowSize {
            buffer.removeFirst(buffer.count - Self.windowSize)
        }
    }

    // MARK: - Prediction

    private func runPrediction() {
        guard let model, isModelAvailable, !buffer.isEmpty else { return }

        // Causal-trailing window: pad by replicating the earliest available
        // sample so the model always sees exactly `windowSize` rows, even
        // right after start() (mirrors imu_sequence.window_for_timestamp's
        // clamp-to-boundary edge handling for the offline/causal case).
        var window = buffer
        if window.count < Self.windowSize, let first = window.first {
            let padCount = Self.windowSize - window.count
            window = Array(repeating: first, count: padCount) + window
        }

        // RAW values, no normalization — the training path
        // (train_hand_classifier --imu-seq → imu_sequence.
        // build_sequence_dataset) feeds the Conv1D raw window_for_timestamp
        // windows, so serve time must match. (An earlier version z-normalized
        // here, mirroring imu_sequence_feature — a function the training
        // path does NOT use — which skewed every live prediction.)

        guard let inputArray = try? MLMultiArray(
            shape: [1, NSNumber(value: Self.windowSize), NSNumber(value: Self.channelCount)],
            dataType: .float32
        ) else { return }

        for (t, row) in window.enumerated() {
            for (c, value) in row.enumerated() {
                inputArray[[0, NSNumber(value: t), NSNumber(value: c)] as [NSNumber]] = NSNumber(value: value)
            }
        }

        do {
            let input = try MLDictionaryFeatureProvider(dictionary: ["imu_window": MLFeatureValue(multiArray: inputArray)])
            let output = try model.prediction(from: input)
            decodePrediction(output)
        } catch {
            print("PosturePredictor: prediction failed: \(error)")
        }
    }


    /// Decodes a Core ML classifier output (string class label +
    /// probabilities dict, as emitted by export_imu_coreml.py's
    /// ClassifierConfig), feeds it into the majority vote, and publishes
    /// the voted label + its confidence.
    private func decodePrediction(_ output: MLFeatureProvider) {
        guard let labelValue = output.featureValue(for: "classLabel")?.stringValue,
              let hand = HoldingHand(rawValue: labelValue)
        else {
            return
        }

        var conf = 0.0
        // "classProbability" is the exporter's contract; "classLabel_probs"
        // is coremltools' raw default — accept either so an un-renamed
        // export still shows a confidence.
        if let probsValue = output.featureValue(for: "classProbability")?.dictionaryValue
            ?? output.featureValue(for: "classLabel_probs")?.dictionaryValue {
            conf = probsValue[labelValue]?.doubleValue ?? 0.0
        }

        latestConfidence[hand] = conf
        recentPredictions.append(hand)
        if recentPredictions.count > Self.voteWindowSize {
            recentPredictions.removeFirst(recentPredictions.count - Self.voteWindowSize)
        }

        // Majority vote over the recent raw predictions. A 3-way tie is
        // possible with 3 votes and 3 classes; keep the currently published
        // posture in that case so a tie never causes flicker.
        var counts: [HoldingHand: Int] = [:]
        for p in recentPredictions { counts[p, default: 0] += 1 }
        let maxCount = counts.values.max() ?? 0
        let winners = counts.filter { $0.value == maxCount }.map(\.key)

        let voted: HoldingHand
        if winners.count == 1 {
            voted = winners[0]
        } else if winners.contains(livePredictedPosture) {
            voted = livePredictedPosture
        } else {
            voted = hand
        }

        livePredictedPosture = voted
        confidence = latestConfidence[voted] ?? conf
    }
}
