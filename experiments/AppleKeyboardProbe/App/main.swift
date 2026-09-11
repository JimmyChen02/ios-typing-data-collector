import UIKit

// Public UIApplication event observation. Always deliver the original event.
// The experiment determines which touches reach this process on each OS.
final class ProbeApplication: UIApplication {
    override func sendEvent(_ event: UIEvent) {
        ProbeLog.shared.observe(event)
        super.sendEvent(event)
    }
}

final class ProbeLog {
    static let shared = ProbeLog()
    var active = false
    var keyboardFrame = CGRect.zero
    var touches = 0
    var keyboardTouches = 0
    var edits = 0
    var rows: [[String]] = []
    var changed: (() -> Void)?
    private var start = ProcessInfo.processInfo.systemUptime

    func begin() {
        start = ProcessInfo.processInfo.systemUptime
        touches = 0; keyboardTouches = 0; edits = 0; rows = []
        active = true
        changed?()
    }

    func observe(_ event: UIEvent) {
        guard active, UIApplication.shared.applicationState == .active else { return }
        for touch in event.allTouches ?? [] where touch.phase == .began {
            guard let window = touch.window else { continue }
            let point = window.convert(touch.location(in: window), to: window.screen.coordinateSpace)
            let inside = !keyboardFrame.isEmpty && keyboardFrame.contains(point)
            touches += 1
            if inside { keyboardTouches += 1 }
            append(kind: "touch_down", uptime: touch.timestamp,
                   x: String(Double(point.x)), y: String(Double(point.y)),
                   inside: inside ? "true" : "false",
                   detail: NSStringFromClass(type(of: window)))
        }
    }

    func edit(_ text: String) {
        guard active else { return }
        edits += 1
        append(kind: "text_change", detail: text)
    }

    func append(kind: String, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                x: String = "", y: String = "", inside: String = "", detail: String = "") {
        rows.append([kind, String((uptime - start) * 1000), x, y, inside,
                     String(Double(keyboardFrame.minX)), String(Double(keyboardFrame.minY)),
                     String(Double(keyboardFrame.width)), String(Double(keyboardFrame.height)), detail])
        changed?()
    }

    var csv: String {
        let header = "event_kind,t_ms,screen_x_pt,screen_y_pt,within_keyboard_frame,keyboard_x_pt,keyboard_y_pt,keyboard_width_pt,keyboard_height_pt,detail\n"
        return header + rows.map { row in
            row.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }
}

final class ProbeController: UIViewController, UITextViewDelegate {
    let editor = UITextView()
    let summary = UILabel()
    let startButton = UIButton(type: .system)
    let exportButton = UIButton(type: .system)
    var notifications: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Apple keyboard · touch probe"
        title.font = .boldSystemFont(ofSize: 21)
        let instruction = UILabel()
        instruction.text = "Start, tap Check once, then type on Apple’s keyboard. This tests whether actual key touches reach the app."
        instruction.numberOfLines = 0
        instruction.font = .systemFont(ofSize: 14)
        startButton.setTitle("Start probe", for: .normal)
        startButton.accessibilityIdentifier = "start"
        startButton.addTarget(self, action: #selector(begin), for: .touchUpInside)
        let control = UIButton(type: .system)
        control.setTitle("Check app touch", for: .normal)
        control.accessibilityIdentifier = "control"
        // Intentionally no action: sendEvent must observe this real touch.
        exportButton.setTitle("Stop & export CSV", for: .normal)
        exportButton.isEnabled = false
        exportButton.addTarget(self, action: #selector(export), for: .touchUpInside)
        summary.numberOfLines = 0
        summary.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        summary.accessibilityIdentifier = "summary"
        editor.delegate = self
        editor.font = .systemFont(ofSize: 22)
        editor.backgroundColor = .secondarySystemBackground
        editor.accessibilityIdentifier = "editor"
        // Leave inputView nil and all text-input traits at Apple's defaults.
        let controls = UIStackView(arrangedSubviews: [startButton, control])
        controls.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [title, instruction, controls, summary, exportButton, editor])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
        ])
        ProbeLog.shared.changed = { [weak self] in self?.refresh() }
        for name in [UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidShowNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    ProbeLog.shared.keyboardFrame = frame
                    self.refresh()
                }
            })
        }
        notifications.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
            ProbeLog.shared.keyboardFrame = .zero
        })
        notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            ProbeLog.shared.active = false
        })
        refresh()
    }

    @objc func begin() {
        editor.text = ""
        ProbeLog.shared.begin()
        exportButton.isEnabled = true
        editor.becomeFirstResponder()
    }

    func refresh() {
        let log = ProbeLog.shared
        summary.text = "iOS \(UIDevice.current.systemVersion)\nApp touches: \(log.touches) · In keyboard: \(log.keyboardTouches)\nText changes: \(log.edits)"
        // UI test retrieval only; this is exactly the same export, not fabricated data.
        summary.accessibilityValue = log.csv
    }

    func textViewDidChange(_ textView: UITextView) {
        ProbeLog.shared.edit(textView.text)
    }

    @objc func export() {
        ProbeLog.shared.active = false
        let name = "native-keyboard-probe-\(Int(Date().timeIntervalSince1970)).csv"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        do {
            try ProbeLog.shared.csv.write(to: url, atomically: true, encoding: .utf8)
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = exportButton
            present(share, animated: true)
        } catch {
            summary.text = "Export failed: \(error.localizedDescription)"
        }
    }
}

final class ProbeDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ProbeController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, NSStringFromClass(ProbeApplication.self), NSStringFromClass(ProbeDelegate.self))
