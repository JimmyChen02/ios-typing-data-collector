import Foundation
import Observation
import SwiftData
import UIKit

// MARK: - PostureCaptureController
//
// D2b — owns the background HandBurstCapture instance + per-frame counter
// for the "Posture training run" typing screen, so TrialView / SessionManager
// stay thin. Reuses HandBurstCapture (front camera, ~2 Hz) exactly like
// HandCaptureView, and calls the SAME saveFrame logic (JPEG through
// HandImageStore, one HandSample per frame) — copied from
// HandCaptureView.swift lines 375-490, NOT duplicating the JPEG-write logic
// itself (that still lives in HandImageStore.shared.saveImage).
//
// Only ever driven from SessionManager.startPostureCapture()/stopPostureCapture(),
// both of which are guarded on isPostureTrainingRun — this class has no
// opinion on that flag itself, it simply does nothing until start() is called.

@MainActor
@Observable
final class PostureCaptureController {

    /// Target sampling rate — same cadence as HandCaptureView's guided burst
    /// (30 fps; was 2 Hz HandyTrak parity).
    private static let targetFPS: Double = 30.0

    /// Serial background queue for JPEG encode + disk write — at 30 fps the
    /// ~5–8 ms encode per frame would otherwise land on the main actor and
    /// compete with keystroke handling (the exact latency PR #29 fought).
    /// Serial so HandSample insertion order matches capture order.
    private static let imageWriteQueue = DispatchQueue(label: "PostureCaptureController.imageWrite", qos: .utility)

    private var capture: HandBurstCapture?
    private var frameIndex: Int = 0

    /// The most recently captured frame — D2c's CameraPreviewOverlay reads
    /// this to show a live preview WITHOUT starting a second
    /// AVCaptureSession (two sessions on the same device may conflict; see
    /// the D2c spec). nil until the first frame arrives, or whenever capture
    /// is stopped/unavailable.
    private(set) var latestFrame: UIImage?

    /// Starts continuous labeled capture. Idempotent — a second start() call
    /// while already running is a no-op (mirrors HandBurstCapture.start()'s
    /// own idempotency, satisfying the "overlay opened/closed repeatedly"
    /// edge case: no duplicate AVCaptureSessions are created).
    ///
    /// - Parameters:
    ///   - onSample: called once per saved (or label-only) HandSample; the
    ///     caller (SessionManager) appends it to pendingHandSamples and is
    ///     responsible for modelContext.insert bookkeeping ordering — this
    ///     controller performs the modelContext.insert itself (same as
    ///     HandCaptureView.saveFrame) and calls onSample afterward so callers
    ///     can additionally track it (e.g. for export).
    func start(
        participant: Participant,
        sessionId: UUID?,
        studyId: UUID,
        posture: HoldingHand,
        modelContext: ModelContext,
        onSample: @escaping (HandSample) -> Void
    ) {
        guard capture == nil else { return }  // already running

        frameIndex = 0

        let engine = HandBurstCapture()
        engine.targetFPS = Self.targetFPS

        engine.onUnavailable = { [weak self] in
            // Camera denied / Simulator / no front camera — degrade to
            // no-frames without crashing; typing continues normally (D2
            // edge case). Stop cleanly so a later start() can retry.
            self?.capture?.stop()
            self?.capture = nil
            self?.latestFrame = nil
        }

        engine.onFrame = { [weak self] image in
            self?.latestFrame = image
            self?.saveFrame(
                image,
                participant: participant,
                sessionId: sessionId,
                studyId: studyId,
                posture: posture,
                modelContext: modelContext,
                onSample: onSample
            )
        }

        capture = engine
        engine.start()
    }

    /// Stops capture. Idempotent. Frames already saved are NOT discarded —
    /// unlike HandCaptureView's early-dismiss-discards-everything behavior,
    /// posture training run data is real training data and survives an
    /// early dismiss of the typing screen (intentional, documented
    /// difference — see SessionManager.stopPostureCapture()).
    func stop() {
        capture?.stop()
        capture = nil
        latestFrame = nil
    }

    // MARK: - Frame saving
    //
    // Mirrors HandCaptureView.saveFrame (lines 455-490) exactly: JPEG via
    // HandImageStore.shared.saveImage; on disk-write failure a label-only
    // HandSample is still saved (never crashes, never drops the label).
    /// capturedAt / studySessionIndex are stamped synchronously at frame
    /// arrival; the JPEG encode + disk write run on imageWriteQueue, then
    /// the HandSample insert + onSample hop back to the main actor. A frame
    /// still in the write queue when stop() is called finishes normally —
    /// its sample is real training data, same rationale as stop()'s
    /// keep-everything policy above.
    private func saveFrame(
        _ image: UIImage,
        participant: Participant,
        sessionId: UUID?,
        studyId: UUID,
        posture: HoldingHand,
        modelContext: ModelContext,
        onSample: @escaping (HandSample) -> Void
    ) {
        let id = UUID()
        let capturedAt = Date()
        let index = frameIndex
        frameIndex += 1

        Self.imageWriteQueue.async {
            // HandImageStore is documented safe to call from any queue.
            let result = HandImageStore.shared.saveImage(image, id: id)
            // Label-only row is valid even when saveImage fails — no crash.
            Task { @MainActor in
                let sample = HandSample(
                    participantId: participant.id,
                    sessionId: sessionId,
                    studyId: studyId,
                    // studySessionIndex = per-frame counter (0,1,2,…), same
                    // strictly-increasing tie-free primary sort-key convention
                    // as HandCaptureView.saveFrame.
                    studySessionIndex: index,
                    capturedAt: capturedAt,
                    holdingHand: posture,
                    imageRelativePath: result?.relativePath ?? "",
                    imuRelativePath: sessionId.map { "imu/\($0.uuidString).csv" } ?? "",
                    imagePixelWidth: result?.pixelWidth ?? 0,
                    imagePixelHeight: result?.pixelHeight ?? 0,
                    cameraPosition: "front",
                    deviceModel: participant.deviceModel,
                    systemVersion: participant.systemVersion,
                    notes: "posture_training_run"
                )
                modelContext.insert(sample)
                onSample(sample)
            }
        }
    }
}
