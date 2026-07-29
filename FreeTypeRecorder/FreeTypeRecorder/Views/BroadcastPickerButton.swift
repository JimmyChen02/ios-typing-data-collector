import SwiftUI
import ReplayKit

/// Wraps `RPSystemBroadcastPickerView` — the only way to start a full-screen
/// broadcast. Tapping it shows the system sheet where the participant picks
/// "FreeTypeRecorder" and taps "Start Broadcast" (iOS requires this explicit
/// user step; no app can auto-start a broadcast). `preferredExtension` is
/// pre-selected to this app's broadcast extension so the participant doesn't
/// have to choose among installed screen recorders.
struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = "jimmyx.freetyperecorder.broadcast"
        // Hide the mic option — this pipeline records screen video only.
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
