#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

/// Click-test entry point for the real editor, UIApplication observer, and CSV
/// logger. Simulator has no front camera / ReplayKit broadcast; this explicitly
/// excludes those services and never creates or uploads a participant session.
struct SimulatorKeyboardClickTestView: View {
    @State private var text = ""
    @State private var active = false
    @State private var editorID = UUID()
    @State private var directory: URL?
    @State private var status = "Tap Start, then click in the editor."
    @State private var savedCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FreeTypeRecorder").font(.title2.bold())
            Text("SIMULATOR CLICK TEST").font(.caption.bold()).foregroundStyle(.orange)
            Text("Apple keyboard · real editor and tap logger\nCamera, broadcast and upload excluded")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Start") { start() }.disabled(active)
                Button("Stop & Save") { stop() }.disabled(!active)
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Text("Taps: \(active ? KeystrokeLogger.shared.measuredTapCount : savedCount)")
                        .monospacedDigit()
                }
            }
            .buttonStyle(.bordered)
            Text(status).font(.caption)
            LoggingTextView(text: $text, isEditable: active)
                .id(editorID)
        }
        .padding()
    }

    private func start() {
        do {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let output = root.appendingPathComponent("SimulatorKeyboardClickTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            directory = output
            text = ""
            editorID = UUID()
            savedCount = 0
            KeystrokeLogger.shared.start()
            CursorLogger.shared.start()
            LastTouchTracker.shared.reset()
            active = true
            status = "Capturing. Click in the editor, then the onscreen keys."
        } catch {
            status = "Cannot start: \(error.localizedDescription)"
        }
    }

    private func stop() {
        guard active, let directory else { return }
        // End editing first so any native commit-on-blur edit is logged too.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        savedCount = KeystrokeLogger.shared.measuredTapCount
        let editsURL = directory.appendingPathComponent("keystrokes.csv")
        _ = KeystrokeLogger.shared.stop(writingTo: editsURL, tapsURL: directory.appendingPathComponent("taps.csv"))
        _ = CursorLogger.shared.stop(writingTo: directory.appendingPathComponent("cursor.csv"))
        active = false
        do {
            try text.write(to: directory.appendingPathComponent("final_text.txt"), atomically: true, encoding: .utf8)
            let metadata: [String: Any] = [
                "testOnly": true,
                "environment": "ios_simulator_mouse_clicks",
                "systemVersion": UIDevice.current.systemVersion,
                "keyboardMode": "system",
                "tapCaptureMethod": "uiapplication_send_event",
                "measuredTapCount": savedCount,
                "excludedServices": ["camera", "broadcast", "imu", "upload"]
            ]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("test_meta.json"), options: .atomic)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("taps.csv").path) else {
                status = "Tap CSV save failed."
                return
            }
            status = "Saved \(savedCount) taps locally. Test data only."
            print("SIMULATOR_CLICK_TEST_EXPORT=\(directory.path)")
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}
#endif
