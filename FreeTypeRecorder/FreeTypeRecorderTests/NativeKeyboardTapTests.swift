import XCTest
import UIKit

@MainActor
final class NativeKeyboardTapTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        KeystrokeLogger.shared.start()
    }

    override func tearDown() async throws {
        _ = KeystrokeLogger.shared.stop(writingTo: directory.appendingPathComponent("unused.csv"))
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample(x: Double = 127, y: Double = 643, width: Double = 390) -> NativeKeyboardTapSample {
        NativeKeyboardTapSample(screenX: x, screenY: y, keyboardScreenX: 10, keyboardScreenY: 540,
                                keyboardWidth: width, keyboardHeight: 300,
                                uptime: ProcessInfo.processInfo.systemUptime, touchWindow: "UIRemoteKeyboardWindow")
    }

    private func output() throws -> (taps: [[String: String]], edits: [[String: String]]) {
        let editsURL = directory.appendingPathComponent("keystrokes.csv")
        let tapsURL = directory.appendingPathComponent("taps.csv")
        _ = KeystrokeLogger.shared.stop(writingTo: editsURL, tapsURL: tapsURL)
        return (try rows(tapsURL), try rows(editsURL))
    }

    private func rows(_ url: URL) throws -> [[String: String]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return lines.dropFirst().map {
            let values = $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(header.count, values.count)
            return Dictionary(uniqueKeysWithValues: zip(header, values))
        }
    }

    func testNativeCoordinatesExportWithoutInventingKeyGeometryOrEditAssociations() throws {
        KeystrokeLogger.shared.logNativeTap(sample())
        KeystrokeLogger.shared.logNativeTap(sample(x: 132, y: 641))
        // A delayed or batched native edit must not claim that it came from the
        // latest touch.
        KeystrokeLogger.shared.logEvent(type: .insert, replacedText: "", replacementText: "a",
                                       rangeStart: 0, rangeLength: 0, resultingTextLength: 1)
        let result = try output()
        XCTAssertEqual(result.taps.count, 2)
        XCTAssertEqual(result.taps[0]["tap_id"], "1")
        XCTAssertEqual(result.taps[0]["tap_x"], "117.0000")
        XCTAssertEqual(result.taps[0]["tap_y"], "103.0000")
        XCTAssertEqual(result.taps[0]["tap_screen_x"], "127.0000")
        XCTAssertEqual(result.taps[0]["tap_screen_y"], "643.0000")
        XCTAssertEqual(result.taps[0]["keyboard_screen_x"], "10.0000")
        XCTAssertEqual(result.taps[0]["keyboard_screen_y"], "540.0000")
        XCTAssertEqual(result.taps[0]["tap_source"], "native_keyboard_region")
        XCTAssertEqual(result.taps[0]["touch_window"], "UIRemoteKeyboardWindow")
        XCTAssertEqual(result.taps[1]["tap_x"], "122.0000")
        for column in ["key_label", "key_x", "key_y", "key_width", "key_height", "tap_local_x", "tap_norm_x"] {
            XCTAssertEqual(result.taps[0][column], "")
        }
        XCTAssertGreaterThanOrEqual(Double(result.taps[0]["t_ms"]!)!, 0)
        XCTAssertEqual(result.edits[0]["tap_id"], "")
        XCTAssertEqual(result.edits[0]["tap_x"], "")
        XCTAssertEqual(result.edits[0]["keyboard_mode"], "system")
    }

    func testTextEditsWithoutTouchesKeepTapFieldsEmpty() throws {
        KeystrokeLogger.shared.logEvent(type: .paste, replacedText: "", replacementText: "hello",
                                       rangeStart: 0, rangeLength: 0, resultingTextLength: 5)
        let result = try output()
        XCTAssertTrue(result.taps.isEmpty)
        XCTAssertEqual(result.edits.first?["keyboard_mode"], "system")
        for field in ["tap_id", "tap_x", "tap_y", "tap_source", "touch_window"] {
            XCTAssertEqual(result.edits.first?[field], "")
        }
    }

    func testNativeSamplesRejectInvalidGeometryAndRespectSessionBoundaries() throws {
        for invalid in [sample(x: .nan), sample(y: .infinity), sample(width: 0), sample(x: 9), sample(x: 400), sample(y: 840)] {
            KeystrokeLogger.shared.logNativeTap(invalid)
        }
        XCTAssertEqual(KeystrokeLogger.shared.measuredTapCount, 0)
        KeystrokeLogger.shared.logNativeTap(sample())
        XCTAssertEqual(try output().taps.count, 1)
        KeystrokeLogger.shared.logNativeTap(sample())
        XCTAssertEqual(KeystrokeLogger.shared.measuredTapCount, 0)
        KeystrokeLogger.shared.start()
        KeystrokeLogger.shared.logNativeTap(sample())
        XCTAssertEqual(try output().taps.first?["tap_id"], "1")
    }

    func testObserverCapturesOnlyActiveEditorKeyboardWindowTouchDowns() throws {
        let capture = NativeKeyboardTouchCapture()
        let appWindow = UIWindow(frame: UIScreen.main.bounds)
        let host = UIViewController()
        appWindow.rootViewController = host
        appWindow.makeKeyAndVisible()
        let editor = UITextView(frame: CGRect(x: 0, y: 100, width: 200, height: 100))
        host.view.addSubview(editor)
        capture.bind(editor)
        XCTAssertTrue(editor.becomeFirstResponder())
        defer {
            capture.unbind(editor)
            editor.resignFirstResponder()
            appWindow.isHidden = true
        }
        let keyboardWindow = UIWindow(frame: UIScreen.main.bounds)
        let frame = CGRect(x: 0, y: 500, width: 390, height: 300)
        NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: appWindow.screen,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)])
        let touch = ProbeTouch()
        touch.testWindow = keyboardWindow
        touch.point = CGPoint(x: 117, y: 603)
        let event = ProbeEvent(touch: touch)
        capture.observe(event)
        XCTAssertEqual(KeystrokeLogger.shared.measuredTapCount, 1)
        XCTAssertEqual(editor.text, "")

        touch.testPhase = .ended
        capture.observe(event)
        touch.testPhase = .began
        touch.testWindow = appWindow
        capture.observe(event)
        touch.testWindow = keyboardWindow
        editor.isEditable = false
        capture.observe(event)
        XCTAssertEqual(KeystrokeLogger.shared.measuredTapCount, 1)

        editor.isEditable = true
        _ = editor.becomeFirstResponder()
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        capture.observe(event)
        XCTAssertEqual(KeystrokeLogger.shared.measuredTapCount, 1)
        XCTAssertEqual(try output().taps.first?["tap_x"], "117.0000")
    }
}

private final class ProbeTouch: UITouch {
    var testWindow: UIWindow?
    var testPhase: UITouch.Phase = .began
    var point = CGPoint.zero
    override var window: UIWindow? { testWindow }
    override var phase: UITouch.Phase { testPhase }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    override func location(in view: UIView?) -> CGPoint { point }
}

private final class ProbeEvent: UIEvent {
    let touch: UITouch
    init(touch: UITouch) { self.touch = touch; super.init() }
    override var allTouches: Set<UITouch>? { [touch] }
}
