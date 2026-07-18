import UIKit

private enum KeyboardAction: Equatable {
    case text(String)
    case shift
    case delete
    case space
    case returnKey
    case changeLayout(KeyboardLayoutMode)
    case nextKeyboard
}

private struct RenderedKey {
    var label: String
    var action: KeyboardAction
    var frame: CGRect
    var isSpecial: Bool
    var color: UIColor
}

private final class KeyboardAccessibilityElement: UIAccessibilityElement {
    var activation: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        activation?()
        return activation != nil
    }
}

private protocol ResearchKeyboardViewDelegate: AnyObject {
    func keyboardView(_ view: ResearchKeyboardView, didTrigger action: KeyboardAction, touch: UITouch?)
    func keyboardView(_ view: ResearchKeyboardView, didMoveSpacebarBy offset: CGFloat)
}

/// Stage-1 system keyboard: colorful iOS-style QWERTY with geometric hit-testing and full event logging.
final class KeyboardViewController: UIInputViewController {
    private let keyboardView = ResearchKeyboardView()
    private let preferences = SharedKeyboardPreferences.shared
    private var sessionID = UUID()
    private var lastKnownContext: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboardView.delegate = self
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardView)
        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.heightAnchor.constraint(equalToConstant: 280)
        ])
        keyboardView.recordingActive = preferences.isRecording
        refreshChrome()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionID = UUID()
        keyboardView.needsInputModeSwitchKey = needsInputModeSwitchKey
        keyboardView.recordingActive = preferences.isRecording
        refreshChrome()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        let context = textDocumentProxy.documentContextBeforeInput
        if let lastKnownContext,
           let context,
           context != lastKnownContext,
           !context.hasPrefix(lastKnownContext),
           !lastKnownContext.hasPrefix(context) {
            log(kind: .externalMutation, rawContext: context)
        }
        refreshChrome()
    }

    private func refreshChrome() {
        keyboardView.recordingActive = preferences.isRecording
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        lastKnownContext = context
        switch textDocumentProxy.returnKeyType {
        case .done: keyboardView.returnLabel = "done"
        case .go: keyboardView.returnLabel = "go"
        case .next: keyboardView.returnLabel = "next"
        case .search: keyboardView.returnLabel = "search"
        case .send: keyboardView.returnLabel = "send"
        case .join: keyboardView.returnLabel = "join"
        case .continue: keyboardView.returnLabel = "continue"
        default: keyboardView.returnLabel = "return"
        }
        if keyboardView.layoutMode == .letters,
           keyboardView.shiftState != .locked,
           context.isEmpty || context.last.map({ ".!?\n".contains($0) }) == true {
            keyboardView.shiftState = .once
        }
    }

    private func handleText(_ text: String, touch: UITouch?) {
        let start = ContinuousClock.now
        let output = keyboardView.isUppercase ? text.uppercased() : text
        textDocumentProxy.insertText(output)
        if keyboardView.shiftState == .once {
            keyboardView.shiftState = .off
        }

        let point = touch?.location(in: keyboardView)
        let frame = point.flatMap { keyboardView.keyFrame(at: $0) }
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1000
        log(
            kind: .touch,
            key: text.lowercased(),
            emittedText: output,
            rawContext: textDocumentProxy.documentContextBeforeInput,
            touch: touch,
            frame: frame,
            latencyMilliseconds: milliseconds
        )
        refreshChrome()
    }

    private func handleDelete() {
        let contextBefore = textDocumentProxy.documentContextBeforeInput
        textDocumentProxy.deleteBackward()
        log(kind: .delete, rawContext: contextBefore)
        refreshChrome()
    }

    private func handleSpace() {
        if let context = textDocumentProxy.documentContextBeforeInput,
           context.hasSuffix(" "),
           context.dropLast().last.map({ $0.isLetter || $0.isNumber }) == true {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            log(
                kind: .insert,
                emittedText: ". ",
                rawContext: textDocumentProxy.documentContextBeforeInput,
                metadata: ["smartDoubleSpace": "true"]
            )
            refreshChrome()
            return
        }
        textDocumentProxy.insertText(" ")
        log(kind: .insert, emittedText: " ", rawContext: textDocumentProxy.documentContextBeforeInput)
        refreshChrome()
    }

    private func handleReturn() {
        textDocumentProxy.insertText("\n")
        log(kind: .insert, emittedText: "\n", rawContext: textDocumentProxy.documentContextBeforeInput)
        refreshChrome()
    }

    private func log(
        kind: KeyboardEventKind,
        key: String? = nil,
        emittedText: String? = nil,
        rawContext: String? = nil,
        touch: UITouch? = nil,
        frame: CGRect? = nil,
        latencyMilliseconds: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        let point = touch?.location(in: keyboardView)
        let precisePoint = touch?.preciseLocation(in: keyboardView)
        EncryptedEventLedger.shared.append(
            KeyboardResearchEvent(
                sessionID: sessionID,
                kind: kind,
                layout: keyboardView.layoutMode,
                key: key,
                emittedText: emittedText,
                rawContext: rawContext,
                contextHash: ContextPrivacy.hash(rawContext),
                touchX: point.map { Double($0.x) },
                touchY: point.map { Double($0.y) },
                preciseTouchX: precisePoint.map { Double($0.x) },
                preciseTouchY: precisePoint.map { Double($0.y) },
                touchRadius: touch.map { Double($0.majorRadius) },
                touchRadiusTolerance: touch.map { Double($0.majorRadiusTolerance) },
                touchForce: touch.map { Double($0.force) },
                touchMaximumForce: touch.map { Double($0.maximumPossibleForce) },
                touchTimestamp: touch?.timestamp,
                touchType: touch.map { $0.type.rawValue },
                keyFrame: frame.map(CodableRect.init),
                latencyMilliseconds: latencyMilliseconds,
                metadata: metadata
            )
        )
    }
}

extension KeyboardViewController: ResearchKeyboardViewDelegate {
    fileprivate func keyboardView(
        _ view: ResearchKeyboardView,
        didTrigger action: KeyboardAction,
        touch: UITouch?
    ) {
        switch action {
        case .text(let text):
            handleText(text, touch: touch)
        case .shift:
            switch view.shiftState {
            case .off: view.shiftState = .once
            case .once: view.shiftState = .locked
            case .locked: view.shiftState = .off
            }
        case .delete:
            handleDelete()
        case .space:
            handleSpace()
        case .returnKey:
            handleReturn()
        case .changeLayout(let mode):
            view.layoutMode = mode
        case .nextKeyboard:
            advanceToNextInputMode()
        }
    }

    fileprivate func keyboardView(_ view: ResearchKeyboardView, didMoveSpacebarBy offset: CGFloat) {
        let characters = Int(offset / 14)
        guard characters != 0 else { return }
        textDocumentProxy.adjustTextPosition(byCharacterOffset: characters)
        log(
            kind: .cursorMoved,
            rawContext: textDocumentProxy.documentContextBeforeInput,
            metadata: ["offset": String(characters)]
        )
    }
}

private final class ResearchKeyboardView: UIView {
    enum ShiftState {
        case off
        case once
        case locked
    }

    weak var delegate: ResearchKeyboardViewDelegate?
    var layoutMode: KeyboardLayoutMode = .letters { didSet { setNeedsLayout(); setNeedsDisplay() } }
    var shiftState: ShiftState = .off { didSet { setNeedsDisplay() } }
    var needsInputModeSwitchKey = true { didSet { setNeedsLayout(); setNeedsDisplay() } }
    var recordingActive = false { didSet { setNeedsDisplay() } }
    var returnLabel = "return" { didSet { setNeedsLayout(); setNeedsDisplay() } }
    var isUppercase: Bool { shiftState != .off }

    private var renderedKeys: [RenderedKey] = []
    private var activeTouch: UITouch?
    private var activeAction: KeyboardAction?
    private var spaceStart: CGPoint?
    private var deleteTimer: Timer?
    private var didRepeatDelete = false

    func keyFrame(at point: CGPoint) -> CGRect? {
        renderedKeys.first(where: {
            $0.frame.insetBy(dx: -2, dy: -4).contains(point)
        })?.frame
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 280)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        backgroundColor = UIColor(red: 0.16, green: 0.18, blue: 0.28, alpha: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildLayout()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawStatusBar(context)
        for key in renderedKeys {
            draw(key: key, context: context)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        activeTouch = touch
        let point = touch.location(in: self)
        activeAction = renderedKeys.first(where: { $0.frame.insetBy(dx: -2, dy: -4).contains(point) })?.action
        if activeAction == .space {
            spaceStart = point
        } else if activeAction == .delete {
            didRepeatDelete = false
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
                self?.beginDeleteRepeat()
            }
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeAction == .space,
              let start = spaceStart,
              let point = touches.first?.location(in: self) else { return }
        if abs(point.x - start.x) > 14 {
            delegate?.keyboardView(self, didMoveSpacebarBy: point.x - start.x)
            spaceStart = point
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        deleteTimer?.invalidate()
        deleteTimer = nil
        guard let action = activeAction else {
            clearTouch()
            return
        }
        if action != .delete || !didRepeatDelete {
            UIDevice.current.playInputClick()
            delegate?.keyboardView(self, didTrigger: action, touch: touches.first ?? activeTouch)
        }
        clearTouch()
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        deleteTimer?.invalidate()
        clearTouch()
        setNeedsDisplay()
    }

    private func clearTouch() {
        activeTouch = nil
        activeAction = nil
        spaceStart = nil
        didRepeatDelete = false
    }

    private func beginDeleteRepeat() {
        didRepeatDelete = true
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.delegate?.keyboardView(self, didTrigger: .delete, touch: self.activeTouch)
        }
    }

    private func rebuildLayout() {
        renderedKeys.removeAll(keepingCapacity: true)
        let side: CGFloat = 4
        let gap: CGFloat = 6
        let statusHeight: CGFloat = 36
        let rowGap: CGFloat = 8
        let rowHeight = max(42, (bounds.height - statusHeight - rowGap * 4 - 6) / 4)
        let top = statusHeight + rowGap

        let rows: [[(String, KeyboardAction, CGFloat, Bool)]]
        switch layoutMode {
        case .letters:
            rows = [
                Array("qwertyuiop").map { (String($0), .text(String($0)), 1, false) },
                Array("asdfghjkl").map { (String($0), .text(String($0)), 1, false) },
                [("shift", .shift, 1.35, true)]
                    + Array("zxcvbnm").map { (String($0), .text(String($0)), 1, false) }
                    + [("⌫", .delete, 1.35, true)],
                bottomRow(letterMode: true)
            ]
        case .numbers:
            rows = [
                Array("1234567890").map { (String($0), .text(String($0)), 1, false) },
                Array("-/:;()$&@\"").map { (String($0), .text(String($0)), 1, false) },
                [("#+=", .changeLayout(.symbols), 1.35, true)]
                    + Array(".,?!'").map { (String($0), .text(String($0)), 1, false) }
                    + [("⌫", .delete, 1.35, true)],
                bottomRow(letterMode: false)
            ]
        case .symbols:
            rows = [
                Array("[]{}#%^*+=").map { (String($0), .text(String($0)), 1, false) },
                Array("_\\|~<>€£¥•").map { (String($0), .text(String($0)), 1, false) },
                [("123", .changeLayout(.numbers), 1.35, true)]
                    + Array(".,?!'").map { (String($0), .text(String($0)), 1, false) }
                    + [("⌫", .delete, 1.35, true)],
                bottomRow(letterMode: false)
            ]
        }

        for (rowIndex, row) in rows.enumerated() {
            let y = top + CGFloat(rowIndex) * (rowHeight + rowGap)
            let totalUnits = row.reduce(0) { $0 + $1.2 }
            let available = bounds.width - side * 2 - gap * CGFloat(max(0, row.count - 1))
            let unitWidth = available / totalUnits
            var x = side
            for (itemIndex, item) in row.enumerated() {
                let width = unitWidth * item.2
                renderedKeys.append(
                    RenderedKey(
                        label: item.0,
                        action: item.1,
                        frame: CGRect(x: x, y: y, width: width, height: rowHeight),
                        isSpecial: item.3,
                        color: keyColor(for: item.1, label: item.0, row: rowIndex, index: itemIndex)
                    )
                )
                x += width + gap
            }
        }
        rebuildAccessibilityElements()
    }

    private func bottomRow(letterMode: Bool) -> [(String, KeyboardAction, CGFloat, Bool)] {
        var row: [(String, KeyboardAction, CGFloat, Bool)] = [
            (letterMode ? "123" : "ABC", .changeLayout(letterMode ? .numbers : .letters), 1.35, true)
        ]
        if needsInputModeSwitchKey {
            row.append(("🌐", .nextKeyboard, 1.05, true))
        }
        row.append(("space", .space, 4.6, false))
        row.append((returnLabel, .returnKey, 1.8, true))
        return row
    }

    private func keyColor(for action: KeyboardAction, label: String, row: Int, index: Int) -> UIColor {
        if case .text(let text) = action, text.count == 1, text.first?.isLetter == true {
            // Distinct per-letter colors so the custom keyboard is unmistakable.
            let palette: [UIColor] = [
                UIColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1), // coral
                UIColor(red: 1.00, green: 0.62, blue: 0.26, alpha: 1), // orange
                UIColor(red: 1.00, green: 0.84, blue: 0.24, alpha: 1), // yellow
                UIColor(red: 0.45, green: 0.88, blue: 0.40, alpha: 1), // green
                UIColor(red: 0.30, green: 0.82, blue: 0.78, alpha: 1), // teal
                UIColor(red: 0.38, green: 0.66, blue: 1.00, alpha: 1), // blue
                UIColor(red: 0.66, green: 0.52, blue: 1.00, alpha: 1), // violet
                UIColor(red: 0.95, green: 0.45, blue: 0.78, alpha: 1), // pink
                UIColor(red: 0.55, green: 0.92, blue: 0.62, alpha: 1), // mint
                UIColor(red: 0.98, green: 0.55, blue: 0.45, alpha: 1)  // salmon
            ]
            let code = Int(text.lowercased().unicodeScalars.first?.value ?? 0)
            return palette[code % palette.count]
        }
        if case .space = action {
            return UIColor(red: 0.55, green: 0.75, blue: 1.00, alpha: 1)
        }
        // Special keys stay darker so the letter colors pop.
        return UIColor(red: 0.28, green: 0.30, blue: 0.42, alpha: 1)
    }

    private func drawStatusBar(_ context: CGContext) {
        UIColor(red: 0.10, green: 0.11, blue: 0.18, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 36))
        let title = recordingActive ? "Research Keyboard · recording" : "Research Keyboard · paused"
        drawText(
            title,
            in: CGRect(x: 12, y: 0, width: bounds.width - 28, height: 36),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .white
        )
        if recordingActive {
            UIColor.systemRed.setFill()
            context.fillEllipse(in: CGRect(x: bounds.width - 14, y: 15, width: 7, height: 7))
        }
    }

    private func draw(key: RenderedKey, context: CGContext) {
        let isActive = activeAction == key.action
        let fill = isActive ? key.color.withAlphaComponent(0.7) : key.color
        fill.setFill()
        let path = UIBezierPath(roundedRect: key.frame, cornerRadius: 7)
        path.fill()
        UIColor.black.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 0.6
        path.stroke()

        var label = key.label
        if case .text = key.action, isUppercase {
            label = label.uppercased()
        } else if key.action == .shift {
            label = shiftState == .locked ? "⇪" : "⇧"
        }
        let textColor: UIColor = key.isSpecial ? .white : UIColor(white: 0.08, alpha: 1)
        drawText(
            label,
            in: key.frame,
            font: .systemFont(ofSize: label.count == 1 ? 22 : 14, weight: .semibold),
            color: textColor
        )
    }

    private func drawText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func rebuildAccessibilityElements() {
        var elements: [UIAccessibilityElement] = []
        for key in renderedKeys {
            let element = KeyboardAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = key.label
            element.accessibilityFrameInContainerSpace = key.frame
            element.accessibilityTraits = .keyboardKey
            element.activation = { [weak self] in
                guard let self else { return }
                self.delegate?.keyboardView(self, didTrigger: key.action, touch: nil)
            }
            elements.append(element)
        }
        accessibilityElements = elements
    }
}

extension ResearchKeyboardView: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
