import ReplayKit
import AVFoundation
import CoreImage
import UIKit

/// Broadcast Upload Extension entry point. Unlike the main app's in-app
/// `RPScreenRecorder.startCapture` — which excludes the system keyboard —
/// a broadcast extension receives the ENTIRE display's frames (keyboard,
/// its key-press popups, the autofill/QuickType bar, everything), because
/// iOS captures the real composited framebuffer here.
///
/// The AVAssetWriter writes to the extension's OWN temporary directory —
/// writing an mp4 directly into the shared App Group container makes
/// AVAssetWriter fail (status .failed), a known broadcast-extension gotcha.
/// On finish, the completed local file is copied into the shared container
/// as `finishedURL` for the app to collect. Coordination
/// (marker / stop-request / finished) is file-based via the shared
/// container; see BroadcastShared. Runs in a separate process with a tight
/// memory budget (~50MB): frames with no recent-keys overlay are appended
/// straight to the writer and released, untouched. Only frames that need the
/// overlay drawn are composited — through one shared, reused `CIContext`
/// into a pooled `CVPixelBuffer` (via `AVAssetWriterInputPixelBufferAdaptor`)
/// — and the overlay image itself is cached by text so it's rebuilt only
/// when the recent-keys text changes.
class SampleHandler: RPBroadcastSampleHandler {

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var stopping = false
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var cachedOverlay: CIImage?
    private var cachedOverlayText: String = ""

    /// Real video output — the extension's own tmp dir, NOT the shared
    /// container (AVAssetWriter fails writing into the app group container).
    private let localVideoURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("broadcast_local.mp4")

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let markerURL = BroadcastShared.activeMarkerURL() else {
            finishBroadcastWithError(NSError(domain: "FreeTypeRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable — is the App Group set up?"]))
            return
        }

        // Drop a marker the instant we launch so the app knows the extension
        // is alive, independent of whether video capture succeeds.
        try? "active".data(using: .utf8)?.write(to: markerURL)

        // Fresh slate — clear the local tmp video and stale shared flags.
        try? FileManager.default.removeItem(at: localVideoURL)
        if let writingURL = BroadcastShared.writingURL() { try? FileManager.default.removeItem(at: writingURL) }
        if let finishedURL = BroadcastShared.finishedURL() { try? FileManager.default.removeItem(at: finishedURL) }
        if let stopURL = BroadcastShared.stopRequestURL() { try? FileManager.default.removeItem(at: stopURL) }

        do {
            assetWriter = try AVAssetWriter(outputURL: localVideoURL, fileType: .mp4)
        } catch {
            BroadcastShared.log.error("EXT AVAssetWriter init failed: \(error.localizedDescription, privacy: .public)")
            finishBroadcastWithError(error)
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // Stop-request (End Early) check runs first, for any sample type, so
        // stopping works even between video frames.
        if !stopping, let stopURL = BroadcastShared.stopRequestURL(),
           FileManager.default.fileExists(atPath: stopURL.path) {
            stopping = true
            try? FileManager.default.removeItem(at: stopURL)
            finishBroadcastWithError(NSError(domain: "FreeTypeRecorder", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Recording finished."]))
            return
        }

        guard sampleBufferType == .video, let assetWriter else { return }

        if videoInput == nil {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
            ])
            input.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(input) else { return }
            assetWriter.add(input)
            videoInput = input
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(dimensions.width),
                    kCVPixelBufferHeightKey as String: Int(dimensions.height),
                ]
            )
        }

        guard let videoInput else { return }

        if !sessionStarted {
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
            // Flag in the shared container so the app's status reflects that
            // video is being written (the real file lives in tmp, not here).
            if let writingURL = BroadcastShared.writingURL() {
                try? Data().write(to: writingURL)
            }
        }

        guard assetWriter.status == .writing, videoInput.isReadyForMoreMediaData else { return }

        // Only the overlay case needs compositing; without it, keep the original
        // zero-copy passthrough to stay well within the extension's memory budget.
        guard let adaptor = pixelBufferAdaptor,
              let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let pool = adaptor.pixelBufferPool else {
            videoInput.append(sampleBuffer)
            return
        }

        // Build the overlay sized to this frame's width so a long log wraps
        // instead of running off the right edge.
        let frameWidth = CGFloat(CVPixelBufferGetWidth(sourceBuffer))
        guard let overlay = overlayImage(
            for: currentRecentKeys(),
            maxWidth: frameWidth * Self.overlayWidthFraction
        ) else {
            videoInput.append(sampleBuffer)
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frameImage = composite(overlay, over: CIImage(cvPixelBuffer: sourceBuffer))
        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
        guard let destBuffer = outBuffer else {
            videoInput.append(sampleBuffer)
            return
        }
        ciContext.render(frameImage, to: destBuffer)
        adaptor.append(destBuffer, withPresentationTime: presentationTime)
    }

    override func broadcastFinished() {
        // Clear the alive marker, in-progress flag, and any stop-request.
        if let markerURL = BroadcastShared.activeMarkerURL() { try? FileManager.default.removeItem(at: markerURL) }
        if let writingURL = BroadcastShared.writingURL() { try? FileManager.default.removeItem(at: writingURL) }
        if let stopURL = BroadcastShared.stopRequestURL() { try? FileManager.default.removeItem(at: stopURL) }

        guard let assetWriter, sessionStarted, assetWriter.status == .writing else { return }

        // broadcastFinished is synchronous from ReplayKit's view; block
        // briefly on a semaphore so finishWriting completes before teardown.
        let semaphore = DispatchSemaphore(value: 0)
        videoInput?.markAsFinished()
        assetWriter.finishWriting {
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)

        // Copy the completed local video into the shared container as the
        // "finished" file — the app's definitive "ready to collect" signal.
        guard let finishedURL = BroadcastShared.finishedURL(),
              FileManager.default.fileExists(atPath: localVideoURL.path) else { return }
        try? FileManager.default.removeItem(at: finishedURL)
        do {
            try FileManager.default.copyItem(at: localVideoURL, to: finishedURL)
        } catch {
            BroadcastShared.log.error("EXT failed to publish recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentRecentKeys() -> String {
        guard let url = BroadcastShared.recentKeysURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    // Rebuilds the pill image only when the text changes. Rendered at 1:1
    // scale (UIGraphicsImageRenderer otherwise uses the device's 2–3× screen
    // scale, oversizing the composite). The font auto-sizes so the text spans
    // about `maxWidth` — passed as ~90% of the frame — so the strip stays
    // large and prominent; it's capped so a very short log doesn't blow up,
    // and wraps within maxWidth if a full log can't fit at the cap.
    private func overlayImage(for text: String, maxWidth: CGFloat) -> CIImage? {
        guard !text.isEmpty, maxWidth > 0 else { return nil }
        if text == cachedOverlayText, let cached = cachedOverlay { return cached }

        let padding: CGFloat = 16
        let targetWidth = max(1, maxWidth - padding * 2)

        // Single-line text width scales ~linearly with point size, so one
        // measurement at a reference size gives the size that fills targetWidth.
        let reference: CGFloat = 40
        let refFont = UIFont.systemFont(ofSize: reference, weight: .semibold)
        let refWidth = (text as NSString).size(withAttributes: [.font: refFont]).width
        let fontSize = min(max(refWidth > 0 ? reference * targetWidth / refWidth : reference, 24), 56)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: targetWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil)
        let textWidth = min(ceil(bounds.width), targetWidth)
        let textHeight = ceil(bounds.height)
        let pillSize = CGSize(width: textWidth + padding * 2, height: textHeight + padding)
        guard pillSize.width > 0, pillSize.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: pillSize, format: format)
        let image = renderer.image { _ in
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: pillSize), cornerRadius: 10)
            UIColor.black.withAlphaComponent(0.6).setFill()
            path.fill()
            (text as NSString).draw(
                with: CGRect(x: padding, y: padding / 2, width: textWidth, height: textHeight),
                options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        }
        let ciImage = image.cgImage.map { CIImage(cgImage: $0) }
        cachedOverlay = ciImage
        cachedOverlayText = text
        return ciImage
    }

    // Places the pill as a band just above the keyboard. CoreImage's origin
    // is bottom-left; the keyboard occupies the lower portion of the frame,
    // so this y sits above it. The fraction may need on-device tuning.
    private static let overlayWidthFraction: CGFloat = 0.9

    private func composite(_ overlay: CIImage, over frame: CIImage) -> CIImage {
        let extent = frame.extent
        let x = (extent.width - overlay.extent.width) / 2   // center the ~90%-wide strip
        let y = extent.height * 0.42
        let positioned = overlay.transformed(by: CGAffineTransform(translationX: x, y: y))
        guard let filter = CIFilter(name: "CISourceOverCompositing") else { return frame }
        filter.setValue(positioned, forKey: kCIInputImageKey)
        filter.setValue(frame, forKey: kCIInputBackgroundImageKey)
        return filter.outputImage ?? frame
    }
}
