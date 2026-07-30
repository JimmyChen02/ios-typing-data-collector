import Foundation
import Observation

/// Coordinates the app-process per-session recorders — segmented-face
/// video, IMU, periodic seg-images (+ manifest), and keystrokes — so a
/// single start/stop pair drives them together, and auto-stops everything
/// at the 3-minute session limit.
///
/// The screen recording is NOT here: it's produced by the separate
/// BroadcastExtension (the only capture path that includes the system
/// keyboard) and collected into the session folder by NotepadView via
/// BroadcastCoordinator after the broadcast ends.
@MainActor
@Observable
final class SessionRecorder {

    static let sessionDuration: TimeInterval = 180

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0

    private let faceWriter = SegmentedFaceCaptureWriter()
    private let segImageManifest = SegImageManifestWriter()
    private var segImageFrameIndex = 0

    private var timer: Timer?
    private var workingDirectory: URL?
    private var onAutoStop: (() -> Void)?

    func start(hand: HoldingHand, onAutoStop: @escaping () -> Void, completion: @escaping (Error?) -> Void) {
        guard !isRecording else { return }

        let directory = RecordingSession.sessionsDirectory()
            .appendingPathComponent(hand.rawValue, isDirectory: true)
            .appendingPathComponent(Self.timestampFolderName(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            completion(error)
            return
        }
        workingDirectory = directory
        self.onAutoStop = onAutoStop
        segImageFrameIndex = 0
        Self.writeMeta(hand: hand, to: directory)

        let sessionID = directory.lastPathComponent
        faceWriter.onSegImage = { [weak self] image, _ in
            guard let self else { return }
            self.segImageFrameIndex += 1
            guard let saved = SegImageStore.save(image, sessionDirectory: directory, frameIndex: self.segImageFrameIndex) else { return }
            self.segImageManifest.addRow(
                participantName: ParticipantStore.shared.name ?? "Unknown",
                sessionID: sessionID,
                frameIndex: self.segImageFrameIndex,
                capturedAt: Date(),
                holdingHand: PosturePredictor.shared.livePredictedPosture,
                imageRelativePath: saved.relativePath,
                imuRelativePath: "imu.csv",
                pixelWidth: saved.pixelWidth,
                pixelHeight: saved.pixelHeight
            )
        }

        IMURecorder.shared.start()
        PosturePredictor.shared.start()
        KeystrokeLogger.shared.start()

        faceWriter.start(outputURL: directory.appendingPathComponent("face.mov")) { [weak self] error in
            guard let self else { return }
            if let error {
                self.isRecording = false
                completion(error)
                return
            }
            self.isRecording = true
            self.elapsed = 0
            self.startTimer()
            completion(nil)
        }
    }

    /// Stops every recorder; `completion` receives the finished session's
    /// directory (nil if recording wasn't active).
    func stop(completion: @escaping (URL?) -> Void) {
        guard isRecording else {
            completion(nil)
            return
        }
        isRecording = false
        timer?.invalidate()
        timer = nil

        PosturePredictor.shared.stop()

        let directory = workingDirectory
        if let directory {
            _ = IMURecorder.shared.stop(writingTo: directory.appendingPathComponent("imu.csv"))
            _ = KeystrokeLogger.shared.stop(writingTo: directory.appendingPathComponent("keystrokes.csv"))
        }

        faceWriter.stop { [weak self] in
            // Only safe to write the manifest once faceWriter has fully
            // stopped — any in-flight frame's onSegImage callback could
            // still add a row up until that point.
            if let directory {
                self?.segImageManifest.write(to: directory.appendingPathComponent("seg_images/manifest.csv"))
            }
            completion(directory)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed += 0.1
                self.updateLiveLabel()
                if self.elapsed >= Self.sessionDuration {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.onAutoStop?()
                }
            }
        }
    }

    // Pushes the current holding-hand prediction into the face video's
    // burned-in label; faceWriter can't read PosturePredictor itself since
    // its compositing runs off the MainActor.
    private func updateLiveLabel() {
        guard PosturePredictor.shared.isModelAvailable else {
            faceWriter.updateLiveLabel("")
            return
        }
        let posture = PosturePredictor.shared.livePredictedPosture
        let confidencePercent = Int(PosturePredictor.shared.confidence * 100)
        faceWriter.updateLiveLabel("\(posture.displayName) \(confidencePercent)%")
    }

    private static func timestampFolderName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }

    private struct SessionMeta: Encodable {
        let participant: String
        let hand: String
        let startedAt: String
    }

    private static func writeMeta(hand: HoldingHand, to directory: URL) {
        let meta = SessionMeta(
            participant: ParticipantStore.shared.name ?? "Unknown",
            hand: hand.rawValue,
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: directory.appendingPathComponent("session_meta.json"))
        }
    }
}
