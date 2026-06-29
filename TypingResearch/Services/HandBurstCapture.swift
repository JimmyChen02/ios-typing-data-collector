import AVFoundation
import UIKit

// MARK: - HandBurstCapture
//
// Front-camera burst frame source for holding-hand data collection.
// Delivers ~`targetFPS` UIImage frames to `onFrame` (main actor).
//
// Safe to construct on Simulator / when permission is denied — it simply
// never emits frames; `start()` reports the problem via `onUnavailable`.
//
// Usage:
//   let capture = HandBurstCapture()
//   capture.onFrame = { image in ... }
//   capture.onUnavailable = { ... }
//   capture.start()
//   // later:
//   capture.stop()

@MainActor
final class HandBurstCapture: NSObject {

    // MARK: - Tunable constants

    /// Target sampling rate matching HandyTrak (~2 Hz).
    var targetFPS: Double = 2.0

    // MARK: - Callbacks (assign before calling start())

    /// Called on the main actor for each throttled frame.
    var onFrame: ((UIImage) -> Void)?

    /// Called on the main actor when the camera cannot be used
    /// (no permission, no front camera, running on Simulator).
    var onUnavailable: (() -> Void)?

    // MARK: - Private AVFoundation state

    private var captureSession: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "HandBurstCapture.session", qos: .userInitiated)

    // Throttle timestamp — read/written only on sessionQueue (the delegate
    // queue), so nonisolated(unsafe) is safe: the session queue is the sole
    // writer/reader and it is a serial queue.
    nonisolated(unsafe) private var lastEmittedPTS: CMTime = .invalid

    // Throttle interval (seconds), captured from `targetFPS` at configure time
    // so the nonisolated delegate callback never reads the main-actor
    // `targetFPS`. Written on the main actor in configureAndStart() before the
    // session starts delivering frames, then read only on sessionQueue.
    nonisolated(unsafe) private var throttleInterval: Double = 0.5

    // Whether start() has already finished configuring a session.
    private var isConfigured: Bool = false

    // MARK: - Public API

    /// Requests camera authorization if needed, then configures and starts
    /// the AVCaptureSession. Idempotent. Calls `onUnavailable` on failure.
    func start() {
        guard !isConfigured else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            // requestAccess must be called off the main thread; deliver result
            // back on the main actor via Task.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.configureAndStart()
                    } else {
                        self?.onUnavailable?()
                    }
                }
            }
        case .denied, .restricted:
            onUnavailable?()
        @unknown default:
            onUnavailable?()
        }
    }

    /// Stops the session. Idempotent.
    /// `stopRunning()` can block; dispatched to sessionQueue.
    func stop() {
        isConfigured = false
        let sessionToStop = captureSession
        captureSession = nil
        sessionQueue.async {
            sessionToStop?.stopRunning()
        }
    }

    // MARK: - Private setup

    private func configureAndStart() {
        // Front camera must exist (Simulator and some iPads don't have one)
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) else {
            onUnavailable?()
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .photo   // high-res, still-like frames

        // Input
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onUnavailable?()
            return
        }
        session.addInput(input)

        // Output — frames delivered on sessionQueue
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)

        guard session.canAddOutput(output) else {
            onUnavailable?()
            return
        }
        session.addOutput(output)

        // Set portrait orientation so frames arrive upright
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        captureSession = session
        isConfigured = true
        lastEmittedPTS = .invalid
        throttleInterval = 1.0 / max(targetFPS, 0.1)

        // startRunning can block; run it off the main thread
        sessionQueue.async {
            session.startRunning()
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension HandBurstCapture: AVCaptureVideoDataOutputSampleBufferDelegate {

    // Called on sessionQueue (the delegate queue set above).
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // --- Frame-rate gate (throttle to targetFPS) ---
        // Use the interval captured at configure time; the main-actor-isolated
        // `targetFPS` cannot be read from this nonisolated delegate callback.
        let targetInterval = throttleInterval
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if lastEmittedPTS != .invalid {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, lastEmittedPTS))
            guard elapsed >= targetInterval else { return }
        }

        // --- Buffer -> UIImage conversion ---
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // CIContext is thread-safe; create per-frame to avoid sharing state.
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        // Front camera output is mirrored. Apply .upMirrored so the saved JPEG
        // shows the real spatial orientation (left side of screen = left in image),
        // which matters for the centroid-baseline left/right discriminator.
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .upMirrored)

        lastEmittedPTS = pts

        // Deliver to SwiftUI on the main actor
        Task { @MainActor [weak self] in
            self?.onFrame?(uiImage)
        }
    }
}
