import ReplayKit
import AVFoundation

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
/// memory budget (~50MB), so it holds no large buffers — each sample is
/// appended straight to the writer and released.
class SampleHandler: RPBroadcastSampleHandler {

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var stopping = false

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
        videoInput.append(sampleBuffer)
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
}
