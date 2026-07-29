import Foundation
import UIKit

/// Builds `seg_images/manifest.csv`. Mirrors the column layout of
/// TypingResearch's DataExporter.exportHandManifestCSV (holding_hand,
/// image/imu relative paths, pixel dims, camera position, device info) so
/// the same offline scripts (scripts/hand_dataset.py /
/// train_hand_classifier.py) can load this data with minor column-name
/// adjustments; participant/session identifier columns are adapted since
/// this app has no "study"/trial concept, just a participant name.
@MainActor
final class SegImageManifestWriter {

    private static let header = "participant_name,session_id,frame_index,captured_at_iso,holding_hand,image_relative_path,imu_relative_path,image_pixel_width,image_pixel_height,camera_position,device_model,system_version,notes\n"

    private var rows: [String] = []

    func addRow(
        participantName: String,
        sessionID: String,
        frameIndex: Int,
        capturedAt: Date,
        holdingHand: HoldingHand,
        imageRelativePath: String,
        imuRelativePath: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        let iso = ISO8601DateFormatter().string(from: capturedAt)
        let device = UIDevice.current
        let row = [
            participantName, sessionID, String(frameIndex), iso, holdingHand.rawValue,
            imageRelativePath, imuRelativePath, String(pixelWidth), String(pixelHeight),
            "front", device.model, device.systemVersion, "",
        ].map(Self.csvEscape).joined(separator: ",")
        rows.append(row)
    }

    /// Writes buffered rows to `outputURL`. No-op if nothing was captured.
    func write(to outputURL: URL) {
        guard !rows.isEmpty else { return }
        let csv = Self.header + rows.joined(separator: "\n") + "\n"
        do {
            try csv.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            print("SegImageManifestWriter: failed to write manifest: \(error)")
        }
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        let doubled = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(doubled)\""
    }
}
