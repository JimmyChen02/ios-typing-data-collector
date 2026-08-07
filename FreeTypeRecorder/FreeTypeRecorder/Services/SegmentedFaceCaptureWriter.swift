import AVFoundation
import Vision
import CoreImage
import UIKit

enum SegmentedFaceCaptureError: Error {
    case noFrontCamera
    case permissionDenied
    case captureSetupFailed
}

/// Front-camera capture where every frame is run through Vision's person
/// segmentation, then reduced to a flat white-silhouette-on-black-background
/// video — never the real color image. This deliberately matches the
/// privacy-preserving binary mask the offline CNN pipeline
/// (scripts/train_hand_classifier.py's "segment" step: FCN-ResNet101 person
/// mask -> binary silhouette) actually trains on, so no recognizable face,
/// skin, or clothing ever reaches disk; only the mask's shape does. The raw
/// camera pixel buffer is used transiently, in memory, solely to compute
/// that mask, and is never itself rendered or written anywhere. Segmentation
/// happens live on-device — unlike the existing hand-posture pipeline
/// (HandBurstCapture / train_hand_classifier.py), which saves raw frames and
/// segments later, offline, in Python. The live PosturePredictor
/// holding-hand prediction is burned into this video's top-right corner
/// (see updateLiveLabel) — deliberately not into the screen recording.
@MainActor
final class SegmentedFaceCaptureWriter: NSObject {

    // .vga640x480 keeps per-frame Vision + CIContext render cost low enough
    // to sustain live frame rate on-device; this video documents typing
    // posture, not a research-grade capture, so resolution is secondary to
    // keeping up with the camera.
    private static let sessionPreset: AVCaptureSession.Preset = .vga640x480
    // Read from the nonisolated capture-delegate callback below (both for
    // the continuous video render and the throttled seg-image snapshot); a
    // plain `static let` on a @MainActor type is otherwise MainActor-isolated
    // too, which the Swift 6 language mode rejects as a cross-actor access.
    private nonisolated static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private nonisolated static let backgroundColor = CIColor.black
    private nonisolated static let silhouetteColor = CIColor.white

    // Cadence for the periodic still-frame capture (independent of the
    // continuous video) that feeds the same offline CNN training pipeline
    // TypingResearch's hand-posture dataset uses, which expects discrete
    // labeled images rather than a video.
    private nonisolated static let segImageInterval: TimeInterval = 1.0
    // Guarded the same way HandBurstCapture's throttle state is: sessionQueue
    // is a serial queue and the sole reader/writer of this value.
    nonisolated(unsafe) private var lastSegImagePTS: CMTime = .invalid

    /// Fired at `segImageInterval` cadence with a still frame of the same
    /// silhouette content being written to video — always on the MainActor.
    var onSegImage: ((UIImage, CMTime) -> Void)?

    // The live holding-hand prediction, burned into the top-right corner of
    // this video (not the screen recording, and not the seg-image stills —
    // those already carry the label as structured manifest data). Written
    // from the MainActor (SessionRecorder's timer), read from the
    // nonisolated capture-delegate callback; a lock guards the cross-actor
    // access since, unlike the throttle PTS above, both sides genuinely
    // write/read concurrently.
    private let labelLock = NSLock()
    nonisolated(unsafe) private var _liveLabelText: String = ""

    private(set) var isRecording = false

    private var captureSession: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "SegmentedFaceCaptureWriter.session", qos: .userInitiated)

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false

    // Held only while finishWriting() is in flight, so the OS grants us the
    // extra runtime to flush the trailing moov if we're finalizing during
    // backgrounding instead of suspending us mid-write. Belt-and-suspenders
    // alongside movieFragmentInterval (which already makes an ungracefully
    // killed recording playable): this keeps the *graceful* background case
    // producing a fully, non-fragment-indexed file.
    private var finishBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    func start(outputURL: URL, completion: @escaping (Error?) -> Void) {
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil else {
            completion(SegmentedFaceCaptureError.noFrontCamera)
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(outputURL: outputURL, completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.configureAndStart(outputURL: outputURL, completion: completion)
                    } else {
                        completion(SegmentedFaceCaptureError.permissionDenied)
                    }
                }
            }
        default:
            completion(SegmentedFaceCaptureError.permissionDenied)
        }
    }

    private func configureAndStart(outputURL: URL, completion: @escaping (Error?) -> Void) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            completion(SegmentedFaceCaptureError.noFrontCamera)
            return
        }

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            // Write the movie header plus periodic fragments *during* capture,
            // rather than only a single moov atom on a clean finishWriting().
            // Without this, an interrupted session (app backgrounded/suspended/
            // killed, or torn down before finishWriting's async completion runs)
            // leaves a file with no moov at all — intact video samples in mdat
            // that no player can index or decode. With a fragment interval the
            // file stays playable up to the last flushed fragment even if
            // finishWriting never completes. Set before startWriting() (below,
            // lazily on the first frame). See finishWriter() for the clean path.
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            assetWriter = writer
        } catch {
            completion(error)
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = Self.sessionPreset

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            completion(SegmentedFaceCaptureError.captureSetupFailed)
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else {
            completion(SegmentedFaceCaptureError.captureSetupFailed)
            return
        }
        session.addOutput(output)

        // Portrait orientation so frames arrive upright (mirrors HandBurstCapture).
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        captureSession = session
        sessionStarted = false
        videoInput = nil
        pixelBufferAdaptor = nil
        lastSegImagePTS = .invalid
        isRecording = true

        sessionQueue.async {
            session.startRunning()
        }
        completion(nil)
    }

    func stop(completion: @escaping () -> Void) {
        guard isRecording else {
            completion()
            return
        }
        isRecording = false
        let sessionToStop = captureSession
        captureSession = nil
        sessionQueue.async { [weak self] in
            sessionToStop?.stopRunning()
            Task { @MainActor in
                self?.finishWriter(completion: completion)
            }
        }
    }

    /// Call periodically (e.g. from SessionRecorder's existing tick timer)
    /// with the current holding-hand prediction text; pass "" to hide it.
    func updateLiveLabel(_ text: String) {
        labelLock.lock()
        _liveLabelText = text
        labelLock.unlock()
    }

    nonisolated private func currentLabelText() -> String {
        labelLock.lock()
        defer { labelLock.unlock() }
        return _liveLabelText
    }

    private func finishWriter(completion: @escaping () -> Void) {
        guard let assetWriter, sessionStarted, assetWriter.status == .writing else {
            completion()
            return
        }
        beginFinishBackgroundTask()
        videoInput?.markAsFinished()
        assetWriter.finishWriting { [weak self] in
            Task { @MainActor in self?.endFinishBackgroundTask() }
            completion()
        }
    }

    private func beginFinishBackgroundTask() {
        endFinishBackgroundTask()
        finishBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinishFaceRecording") { [weak self] in
            Task { @MainActor in self?.endFinishBackgroundTask() }
        }
    }

    private func endFinishBackgroundTask() {
        guard finishBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(finishBackgroundTask)
        finishBackgroundTask = .invalid
    }

    // Runs on the MainActor after a hop from the capture delegate queue.
    // The writer input/pixel-buffer pool is set up lazily on the first frame
    // since its dimensions depend on the actual (post-rotation) image extent
    // rather than anything knowable ahead of time from the session preset.
    private func appendComposited(_ image: CIImage, presentationTime: CMTime) {
        guard let assetWriter else { return }

        if videoInput == nil {
            let width = Int(image.extent.width)
            let height = Int(image.extent.height)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ]
            )
            guard assetWriter.canAdd(input) else { return }
            assetWriter.add(input)
            videoInput = input
            pixelBufferAdaptor = adaptor
        }

        guard let videoInput, let adaptor = pixelBufferAdaptor else { return }

        if !sessionStarted {
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: presentationTime)
            sessionStarted = true
        }

        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else { return }

        Self.ciContext.render(image, to: pixelBuffer)
        adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
    }
}

extension SegmentedFaceCaptureWriter: AVCaptureVideoDataOutputSampleBufferDelegate {

    // Called on sessionQueue (the delegate queue set above). Vision
    // segmentation runs synchronously here — it's CPU/GPU-bound work already
    // off the main thread, matching HandBurstCapture's delegate pattern.
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .upMirrored, options: [:])
        guard (try? handler.perform([request])) != nil,
              let maskBuffer = request.results?.first?.pixelBuffer else { return }

        // Only the frame's pixel dimensions are needed from here on — the
        // actual camera image (`pixelBuffer`) was already consumed above,
        // purely to compute `maskBuffer`, and is deliberately never turned
        // into a CIImage or rendered; nothing downstream can leak real
        // pixels. Front camera output is mirrored; .upMirrored matches
        // HandBurstCapture's convention so the silhouette's left/right
        // matches how the user actually sees themselves.
        let frameExtent = CGRect(
            x: 0, y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        var maskImage = CIImage(cvPixelBuffer: maskBuffer).oriented(.upMirrored)

        // The segmentation mask's native resolution can differ from the
        // camera frame's; scale it up to match before blending.
        let scaleX = frameExtent.width / maskImage.extent.width
        let scaleY = frameExtent.height / maskImage.extent.height
        maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let silhouette = CIImage(color: Self.silhouetteColor).cropped(to: frameExtent)
        let background = CIImage(color: Self.backgroundColor).cropped(to: frameExtent)

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return }
        blend.setValue(silhouette, forKey: kCIInputImageKey)
        blend.setValue(background, forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskImage, forKey: kCIInputMaskImageKey)
        guard let composited = blend.outputImage else { return }

        // The label goes on the video only — seg-image stills stay plain
        // silhouettes, since holding_hand is already recorded as structured
        // data in their manifest row rather than needing to be in the pixels.
        let labeled = Self.overlayLabel(currentLabelText(), on: composited, frameExtent: frameExtent)
        Task { @MainActor [weak self] in
            self?.appendComposited(labeled, presentationTime: presentationTime)
        }

        // Reuses the same (unlabeled) composited silhouette already computed
        // above — no second segmentation pass — just throttled to a much
        // lower cadence for the discrete-image dataset.
        if shouldCaptureSegImage(at: presentationTime),
           let cgImage = Self.ciContext.createCGImage(composited, from: composited.extent) {
            let uiImage = UIImage(cgImage: cgImage)
            Task { @MainActor [weak self] in
                self?.onSegImage?(uiImage, presentationTime)
            }
        }
    }

    nonisolated private func shouldCaptureSegImage(at pts: CMTime) -> Bool {
        if lastSegImagePTS == .invalid {
            lastSegImagePTS = pts
            return true
        }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, lastSegImagePTS))
        guard elapsed >= Self.segImageInterval else { return false }
        lastSegImagePTS = pts
        return true
    }

    // Composites a small "Left hand 82%"-style pill into the top-right
    // corner of `image`. CoreImage's coordinate origin is bottom-left, so
    // "top" means a y close to frameExtent.height, not 0.
    nonisolated private static func overlayLabel(_ text: String, on image: CIImage, frameExtent: CGRect) -> CIImage {
        guard !text.isEmpty, let label = labelImage(text: text) else { return image }
        let margin: CGFloat = 12
        let x = frameExtent.width - label.extent.width - margin
        let y = frameExtent.height - label.extent.height - margin
        let positioned = label.transformed(by: CGAffineTransform(translationX: x, y: y))

        guard let composite = CIFilter(name: "CISourceOverCompositing") else { return image }
        composite.setValue(positioned, forKey: kCIInputImageKey)
        composite.setValue(image, forKey: kCIInputBackgroundImageKey)
        return composite.outputImage ?? image
    }

    nonisolated private static func labelImage(text: String) -> CIImage? {
        let font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let padding: CGFloat = 8
        let textSize = (text as NSString).size(withAttributes: attributes)
        let pillSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding)
        guard pillSize.width > 0, pillSize.height > 0 else { return nil }

        let renderer = UIGraphicsImageRenderer(size: pillSize)
        let uiImage = renderer.image { _ in
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: pillSize), cornerRadius: 6)
            UIColor.black.withAlphaComponent(0.55).setFill()
            path.fill()
            (text as NSString).draw(at: CGPoint(x: padding, y: padding / 2), withAttributes: attributes)
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
