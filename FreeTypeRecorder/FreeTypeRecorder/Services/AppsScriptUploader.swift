import Foundation

enum AppsScriptUploadError: Error {
    case notConfigured
    case invalidResponse(Int)
    case serverError(String)
}

/// Uploads a session's files (videos, IMU/keystroke CSVs, seg-image
/// JPEGs + manifest) directly — no zip, one file per request — to a
/// Google Apps Script Web App endpoint bound to the *researcher's* own
/// Google account/Drive — not the participant's. Because the script runs
/// as the researcher, there's no OAuth, no sign-in, and no Files picker
/// for a participant to go through: every install of the app can upload
/// with zero per-device setup, unlike FolderBackupService (which still
/// requires one local folder pick and is kept as an optional second path,
/// e.g. for the researcher's own device).
///
/// See docs/AUTOMATIC_DRIVE_UPLOAD.md for the one-time script deployment.
@MainActor
final class AppsScriptUploader {
    static let shared = AppsScriptUploader()

    private static let webAppURLString = "https://script.google.com/macros/s/AKfycbxeWbSvU6kJ2mA6QhnatH6aHCzrhVYY1PassUfWerCRKrmQ7VA6VcviB-SwuzC_NHjo/exec"
    private static let sharedToken = "dafjadsfjUDHS12321tiffimu976"

    var isConfigured: Bool {
        URL(string: Self.webAppURLString) != nil
    }

    // Apps Script Web Apps answer with a 302 redirect to the actual content
    // host (script.googleusercontent.com); a plain URLSession can silently
    // drop the POST body/method on that hop depending on iOS version, so a
    // delegate re-attaches them explicitly rather than trusting the default.
    private let session: URLSession
    private let redirectDelegate = PostRedirectPreservingDelegate()

    private init() {
        session = URLSession(configuration: .default, delegate: redirectDelegate, delegateQueue: nil)
    }

    /// Uploads a single file (e.g. `screen.mov`, or `seg_images/0001.jpg`);
    /// the script files it under
    /// `<participant>/<sessionID>/<relativePath>` in Drive, recreating any
    /// subfolders `relativePath` implies.
    func upload(fileURL: URL, relativePath: String, participantName: String, sessionID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isConfigured, let url = URL(string: Self.webAppURLString) else {
            completion(.failure(AppsScriptUploadError.notConfigured))
            return
        }

        do {
            let fileData = try Data(contentsOf: fileURL)
            let body = try JSONSerialization.data(withJSONObject: [
                "token": Self.sharedToken,
                "relativePath": relativePath,
                "participant": participantName,
                "sessionId": sessionID,
                "data": fileData.base64EncodedString(),
            ])

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            session.dataTask(with: request) { data, response, error in
                Task { @MainActor in
                    Self.handleResponse(data: data, response: response, error: error, completion: completion)
                }
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }

    private static func handleResponse(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        completion: (Result<Void, Error>) -> Void
    ) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            completion(.failure(AppsScriptUploadError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? -1)))
            return
        }

        // Apps Script answers via a redirect to a script.googleusercontent.com
        // "echo" URL carrying the actual response body. Under some Workspace
        // domain sharing policies that echo URL isn't reliably fetchable by a
        // plain anonymous client — confirmed empirically (2026-07-24): every
        // POST that reached this deployment executed doPost and created the
        // file in Drive, even on runs where this code could only read back
        // an unrelated Google-hosted placeholder page instead of our JSON.
        // So: an explicit `{ ok: false }` is a real failure; anything else,
        // including an unreadable/non-JSON body, is treated as success,
        // since the request demonstrably reached and ran the script.
        struct ScriptResponse: Decodable {
            let ok: Bool?
            let error: String?
        }
        if let data, let decoded = try? JSONDecoder().decode(ScriptResponse.self, from: data), decoded.ok == false {
            completion(.failure(AppsScriptUploadError.serverError(decoded.error ?? "unknown error")))
            return
        }
        completion(.success(()))
    }
}

private final class PostRedirectPreservingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest, original.httpMethod == "POST" else {
            completionHandler(request)
            return
        }
        var redirected = request
        redirected.httpMethod = "POST"
        redirected.httpBody = original.httpBody
        redirected.setValue(original.value(forHTTPHeaderField: "Content-Type"), forHTTPHeaderField: "Content-Type")
        completionHandler(redirected)
    }
}
