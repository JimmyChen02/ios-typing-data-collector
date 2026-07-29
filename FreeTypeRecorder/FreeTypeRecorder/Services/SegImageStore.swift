import Foundation
import UIKit

/// Saves periodic silhouette-video stills into a session's `seg_images/`
/// folder as JPEGs, for feeding the same offline CNN training pipeline
/// (scripts/train_hand_classifier.py) TypingResearch's hand-posture
/// dataset already uses — that pipeline expects discrete labeled images,
/// not a continuous video.
enum SegImageStore {
    static func save(
        _ image: UIImage,
        sessionDirectory: URL,
        frameIndex: Int
    ) -> (relativePath: String, pixelWidth: Int, pixelHeight: Int)? {
        let folder = sessionDirectory.appendingPathComponent("seg_images", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("SegImageStore: failed to create seg_images folder: \(error)")
            return nil
        }

        guard let jpegData = image.jpegData(compressionQuality: 0.8) else { return nil }
        let filename = String(format: "%04d.jpg", frameIndex)
        let fileURL = folder.appendingPathComponent(filename)
        do {
            try jpegData.write(to: fileURL)
        } catch {
            print("SegImageStore: failed to write \(filename): \(error)")
            return nil
        }

        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return (relativePath: "seg_images/\(filename)", pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}
