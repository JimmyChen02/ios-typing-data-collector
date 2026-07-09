import Foundation
import UIKit

// MARK: - HandImageStore
//
// Stores JPEG images captured from the front camera for holding-hand
// classification (HandyTrak-style pipeline).
//
// Storage layout: `Documents/hand_images/<uuid>.jpg`
//
// All public methods are safe to call from any queue and never crash on
// failure — they return nil / empty results instead.

final class HandImageStore {

    static let shared = HandImageStore()
    private init() {}

    // MARK: - Public API

    /// Saves `image` as a JPEG (quality 0.8) to `Documents/hand_images/<id>.jpg`.
    /// Creates the `hand_images` directory if it doesn't exist.
    /// Returns `(relativePath, pixelWidth, pixelHeight)` on success, nil on failure.
    func saveImage(_ image: UIImage, id: UUID) -> (relativePath: String, pixelWidth: Int, pixelHeight: Int)? {
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            print("HandImageStore: JPEG encoding failed for \(id)")
            return nil
        }

        let dir = imagesDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("HandImageStore: could not create hand_images dir: \(error)")
            return nil
        }

        let filename = "\(id.uuidString).jpg"
        let fileURL = dir.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("HandImageStore: write failed: \(error)")
            return nil
        }

        let relativePath = "hand_images/\(filename)"
        let w = Int(image.size.width  * image.scale)
        let h = Int(image.size.height * image.scale)
        return (relativePath, w, h)
    }

    /// Resolves a relative path (e.g. `hand_images/<uuid>.jpg`) under Documents/.
    func imageURL(relativePath: String) -> URL {
        documentsDirectory().appendingPathComponent(relativePath)
    }

    /// All image URLs currently stored in `Documents/hand_images/`.
    func allImageURLs() -> [URL] {
        let dir = imagesDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }
        return contents.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.path < $1.path }
    }

    /// Removes the entire `hand_images/` directory and its contents.
    /// Call only from the destructive "New participant" reset path.
    func deleteAll() {
        try? FileManager.default.removeItem(at: imagesDirectory())
    }

    // MARK: - Storage Helpers

    private func documentsDirectory() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func imagesDirectory() -> URL {
        documentsDirectory().appendingPathComponent("hand_images")
    }
}
