import Foundation
import Observation
import CoreML

// Ported from TypingResearch/Services/PosturePredictor.swift — same bundled
// model, window size, and majority-vote smoothing, wired to this app's
// IMURecorder instead of MotionRecorder. See that file for the original
// tuning rationale (window/vote sizes chosen there via dense_window_sweep.py).
@MainActor
@Observable
final class PosturePredictor {

    static let shared = PosturePredictor()

    static let modelResourceName = "posture_imu"
    static let windowSize = 50
    static let channelCount = 12
    private static let predictionInterval: TimeInterval = 1.0 / 30.0
    private static let voteWindowSize = 45

    private(set) var livePredictedPosture: HoldingHand = .unknown
    private(set) var confidence: Double = 0.0
    private(set) var isModelAvailable: Bool = false

    private var model: MLModel?
    private var buffer: [[Double]] = []
    private var predictionTimer: Timer?
    private var isRunning: Bool = false

    private var recentPredictions: [HoldingHand] = []
    private var latestConfidence: [HoldingHand: Double] = [:]

    private init() {
        loadModel()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        buffer.removeAll(keepingCapacity: true)

        guard isModelAvailable else { return }

        IMURecorder.shared.onFrame = { [weak self] frame in
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

    func stop() {
        isRunning = false
        predictionTimer?.invalidate()
        predictionTimer = nil
        if IMURecorder.shared.onFrame != nil {
            IMURecorder.shared.onFrame = nil
        }
        buffer.removeAll(keepingCapacity: true)
        recentPredictions.removeAll(keepingCapacity: true)
        latestConfidence.removeAll(keepingCapacity: true)
        livePredictedPosture = .unknown
        confidence = 0.0
    }

    private func loadModel() {
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

    private func appendFrame(_ frame: IMURecorder.MotionFrame) {
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

    private func runPrediction() {
        guard let model, isModelAvailable, !buffer.isEmpty else { return }

        var window = buffer
        if window.count < Self.windowSize, let first = window.first {
            let padCount = Self.windowSize - window.count
            window = Array(repeating: first, count: padCount) + window
        }

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

    private func decodePrediction(_ output: MLFeatureProvider) {
        guard let labelValue = output.featureValue(for: "classLabel")?.stringValue,
              let hand = HoldingHand(rawValue: labelValue)
        else {
            return
        }

        var conf = 0.0
        if let probsValue = output.featureValue(for: "classProbability")?.dictionaryValue
            ?? output.featureValue(for: "classLabel_probs")?.dictionaryValue {
            conf = probsValue[labelValue]?.doubleValue ?? 0.0
        }

        latestConfidence[hand] = conf
        recentPredictions.append(hand)
        if recentPredictions.count > Self.voteWindowSize {
            recentPredictions.removeFirst(recentPredictions.count - Self.voteWindowSize)
        }

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
