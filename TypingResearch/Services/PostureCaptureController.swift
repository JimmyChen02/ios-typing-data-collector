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

    /// Target sampling rate — same cadence as HandCaptureView's guided burst.
    private static let targetFPS: Double = 2.0

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
            // studySessionIndex = per-frame counter (0,1,2,…), same
            // strictly-increasing tie-free primary sort-key convention as
            // HandCaptureView.saveFrame.
            studySessionIndex: frameIndex,
            capturedAt: Date(),
            holdingHand: posture,
            imageRelativePath: rel,
            imuRelativePath: sessionId.map { "imu/\($0.uuidString).csv" } ?? "",
            imagePixelWidth: w,
            imagePixelHeight: h,
            cameraPosition: "front",
            deviceModel: participant.deviceModel,
            systemVersion: participant.systemVersion,
            notes: "posture_training_run"
        )
        modelContext.insert(sample)
        onSample(sample)
        frameIndex += 1
    }
}
