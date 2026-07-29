import UIKit

private enum KeyboardAction: Equatable {
    case text(String)
    case shift
    case delete
    case deleteWord
    case space
    case returnKey
    case changeLayout(KeyboardLayoutMode)
    case nextKeyboard
    case candidate(String)
    case setOneHanded(OneHandedMode)
}

private struct RenderedKey {
    var label: String
    var action: KeyboardAction
    var frame: CGRect
    var isSpecial: Bool
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
    func keyboardView(_ view: ResearchKeyboardView, didMoveCursorBy offset: Int)
    func keyboardView(_ view: ResearchKeyboardView, didMoveCursorVerticallyBy lines: Int)
}

/// Stage-3 iOS-replica keyboard: QWERTY + emoji page, alternates, one-handed, trackpad, logging.
final class KeyboardViewController: UIInputViewController {
    private let keyboardView = ResearchKeyboardView()
    private let emojiView = EmojiKeyboardView()
    private let preferences = SharedKeyboardPreferences.shared
    private let languageDecoder = LocalLanguageDecoder()
    private var heightConstraint: NSLayoutConstraint?
    private var sessionID = UUID()
    private var lastKnownContext: String?
    private var currentWord = ""
    private var previousWord: String?
    private var lastAutocorrect: (original: String, replacement: String, timestamp: Date)?
    private var lastLoggedCandidateTexts: [String] = []
    private var refreshWorkItem: DispatchWorkItem?
    private var hasAppliedInitialLayout = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private var isLandscape: Bool {
        // A keyboard view is always wider than it is tall, even in portrait.
        // Determine orientation from the scene/screen, never from view.bounds.
        if let orientation = view.window?.windowScene?.interfaceOrientation,
           orientation != .unknown {
            return orientation.isLandscape
        }
        let screenBounds = view.window?.windowScene?.screen.bounds ?? UIScreen.main.bounds
        return screenBounds.width > screenBounds.height
    }

    private var preferredHeight: CGFloat {
        // Device-adaptive sizing (closest possible with public APIs): scales by
        // short-side class instead of hardcoded model constants.
        let screenBounds = view.window?.windowScene?.screen.bounds ?? UIScreen.main.bounds
        let shortSide = min(screenBounds.width, screenBounds.height)
        let landscape = isLandscape
        let t = clamp((shortSide - 320) / 108, min: 0, max: 1) // 320...428pt iPhones
        let base: CGFloat = landscape
            ? (156 + t * 14)  // ~156...170
            : (206 + t * 17)  // ~206...223
        let bar: CGFloat
        if preferences.predictiveEnabled {
            bar = landscape ? (32 + t * 3) : (40 + t * 4) // ~32...35 or ~40...44
        } else {
            bar = 0
        }
        return base + bar
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.max(lower, Swift.min(upper, value))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboardView.delegate = self
        emojiView.delegate = self
        for child in [keyboardView, emojiView] as [UIView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        emojiView.isHidden = true

        let height = view.heightAnchor.constraint(equalToConstant: preferredHeight)
        // Keep this required so the keyboard does not appear stretched on first show.
        height.priority = .required
        height.isActive = true
        heightConstraint = height

        haptic.prepare()
        registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) {
            (self: Self, _: UITraitCollection) in
            self.heightConstraint?.constant = self.preferredHeight
            self.keyboardView.isLandscape = self.isLandscape
            self.keyboardView.deviceClassScale = self.deviceClassScale
        }
        applyPreferences()
        refreshContextAndCandidates()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasAppliedInitialLayout = false
        sessionID = UUID()
        keyboardView.needsInputModeSwitchKey = needsInputModeSwitchKey
        emojiView.showsGlobeKey = needsInputModeSwitchKey
        emojiView.reloadCategories()
        applyPreferences()
        refreshContextAndCandidates()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        heightConstraint?.constant = preferredHeight
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let target = preferredHeight
        if abs((heightConstraint?.constant ?? 0) - target) > 0.5 {
            heightConstraint?.constant = target
        }
        // Force one stable post-activation pass so first render isn't stretched.
        if !hasAppliedInitialLayout, view.bounds.width > 0, view.bounds.height > 0 {
            hasAppliedInitialLayout = true
            keyboardView.isLandscape = isLandscape
            keyboardView.deviceClassScale = deviceClassScale
            view.layoutIfNeeded()
            scheduleRefreshContextAndCandidates(immediate: true)
        }
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
            lastAutocorrect = nil
        }
        // Coalesce rapid callbacks while the user is typing quickly.
        scheduleRefreshContextAndCandidates()
    }

    private func applyPreferences() {
        keyboardView.recordingActive = preferences.isRecording
        keyboardView.characterPreviewEnabled = preferences.characterPreviewEnabled
        keyboardView.capsLockEnabled = preferences.capsLockEnabled
        keyboardView.showsCandidateBar = preferences.predictiveEnabled
        keyboardView.oneHandedMode = preferences.oneHandedMode
        keyboardView.isLandscape = isLandscape
        keyboardView.deviceClassScale = deviceClassScale
        heightConstraint?.constant = preferredHeight
    }

    private var deviceClassScale: CGFloat {
        let screenBounds = view.window?.windowScene?.screen.bounds ?? UIScreen.main.bounds
        let shortSide = min(screenBounds.width, screenBounds.height)
        return clamp((shortSide - 320) / 108, min: 0, max: 1)
    }

    private func refreshContextAndCandidates() {
        applyPreferences()
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        lastKnownContext = context
        updateWordContext(from: context)

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
        keyboardView.returnKeyIsPrimary = {
            switch textDocumentProxy.returnKeyType {
            case .default, .none: return false
            default: return true
            }
        }()

        if preferences.autoCapitalizationEnabled,
           keyboardView.layoutMode == .letters,
           keyboardView.shiftState != .locked,
           shouldAutoCapitalize(after: context) {
            keyboardView.shiftState = .once
        }

        if !preferences.predictiveEnabled {
            keyboardView.candidates = []
            if let autocorrect = lastAutocorrect,
               Date().timeIntervalSince(autocorrect.timestamp) < 4 {
                keyboardView.pendingCorrectionDisplay = (
                    original: autocorrect.original,
                    replacement: autocorrect.replacement
                )
            } else {
                keyboardView.pendingCorrectionDisplay = nil
            }
            return
        }
        let candidates = languageDecoder.candidates(for: currentWord, previousWord: previousWord)
        let texts = candidates.map(\.text)
        keyboardView.candidates = texts

        if let autocorrect = lastAutocorrect,
           Date().timeIntervalSince(autocorrect.timestamp) < 4 {
            keyboardView.pendingCorrectionDisplay = (
                original: autocorrect.original,
                replacement: autocorrect.replacement
            )
        } else {
            keyboardView.pendingCorrectionDisplay = nil
        }

        if !texts.isEmpty, texts != lastLoggedCandidateTexts {
            lastLoggedCandidateTexts = texts
            log(kind: .candidateShown, rawContext: context, candidates: candidates)
        }
    }

    private func updateWordContext(from context: String) {
        currentWord = context
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .last
            .map(String.init) ?? ""
        if context.last.map({ $0.isWhitespace || $0.isPunctuation }) == true {
            currentWord = ""
        }
        let words = context.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        previousWord = words.dropLast(currentWord.isEmpty ? 0 : 1).last.map(String.init)
    }

    private func scheduleRefreshContextAndCandidates(immediate: Bool = false) {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshContextAndCandidates()
        }
        refreshWorkItem = work
        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        }
    }

    private func shouldAutoCapitalize(after context: String) -> Bool {
        guard let last = context.last else { return true }
        if last == "\n" { return true }
        guard last == " " else { return false }
        // Capitalize after sentence-ending punctuation followed by a space.
        let trimmed = context.dropLast()
        return trimmed.last.map { ".!?".contains($0) } ?? false
    }

    private func handleText(_ text: String, touch: UITouch?) {
        let start = ContinuousClock.now
        var output = text

        if preferences.smartPunctuationEnabled {
            if SmartPunctuation.completesEmDash(text, contextBefore: textDocumentProxy.documentContextBeforeInput) {
                textDocumentProxy.deleteBackward()
                output = "—"
            } else {
                output = SmartPunctuation.substitution(
                    for: text,
                    contextBefore: textDocumentProxy.documentContextBeforeInput
                )
            }
        }

        // Like iOS, sentence punctuation commits a pending typo correction too.
        if output.count == 1,
           let scalar = output.unicodeScalars.first,
           CharacterSet(charactersIn: ".,!?;:").contains(scalar),
           textDocumentProxy.documentContextBeforeInput?.last?.isLetter == true {
            updateWordContext(from: textDocumentProxy.documentContextBeforeInput ?? "")
            _ = applyAutocorrectIfNeeded(trailing: "", trigger: "punctuation")
        }

        // Punctuation directly after a space: drop the space first, like iOS.
        if output.count == 1,
           let scalar = output.unicodeScalars.first,
           CharacterSet(charactersIn: ".,!?;:").contains(scalar),
           textDocumentProxy.documentContextBeforeInput?.last == " " {
            textDocumentProxy.deleteBackward()
        }

        if output.count == 1, output.first?.isLetter == true, keyboardView.isUppercase {
            output = output.uppercased()
        }
        textDocumentProxy.insertText(output)
        if keyboardView.shiftState == .once, text.first?.isLetter == true {
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
            latencyMilliseconds: milliseconds,
            metadata: output == text ? [:] : ["substituted": "true"]
        )
        scheduleRefreshContextAndCandidates()
    }

    private func handleDelete() {
        let contextBefore = textDocumentProxy.documentContextBeforeInput
        if let autocorrect = lastAutocorrect,
           Date().timeIntervalSince(autocorrect.timestamp) < 4,
           contextBefore?.hasSuffix("\(autocorrect.replacement) ") == true
            || contextBefore?.hasSuffix(autocorrect.replacement) == true {
            let suffixHasSpace = contextBefore?.hasSuffix("\(autocorrect.replacement) ") == true
            let deleteCount = autocorrect.replacement.count + (suffixHasSpace ? 1 : 0)
            for _ in 0..<deleteCount {
                textDocumentProxy.deleteBackward()
            }
            textDocumentProxy.insertText(autocorrect.original)
            log(
                kind: .autocorrectReverted,
                emittedText: autocorrect.original,
                rawContext: textDocumentProxy.documentContextBeforeInput,
                metadata: ["reverted": autocorrect.replacement]
            )
            lastAutocorrect = nil
            keyboardView.pendingCorrectionDisplay = nil
            scheduleRefreshContextAndCandidates()
            return
        }
        textDocumentProxy.deleteBackward()
        lastAutocorrect = nil
        keyboardView.pendingCorrectionDisplay = nil
        log(kind: .delete, rawContext: contextBefore)
        scheduleRefreshContextAndCandidates()
    }

    /// Sustained backspace switches to word deletion, matching iOS.
    private func handleDeleteWord() {
        let contextBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        guard !contextBefore.isEmpty else { return }
        var deleted = 0
        var remaining = Substring(contextBefore)
        while let last = remaining.last, last == " " {
            textDocumentProxy.deleteBackward()
            remaining = remaining.dropLast()
            deleted += 1
        }
        while let last = remaining.last, !last.isWhitespace {
            textDocumentProxy.deleteBackward()
            remaining = remaining.dropLast()
            deleted += 1
        }
        lastAutocorrect = nil
        log(kind: .delete, rawContext: contextBefore, metadata: ["deletedCharacters": String(deleted)])
        scheduleRefreshContextAndCandidates()
    }

    private func handleSpace() {
        updateWordContext(from: textDocumentProxy.documentContextBeforeInput ?? "")
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
            lastAutocorrect = nil
            returnToLettersAfterSpaceIfNeeded()
            scheduleRefreshContextAndCandidates()
            return
        }

        if applyAutocorrectIfNeeded(trailing: " ", trigger: "space") {
            returnToLettersAfterSpaceIfNeeded()
            scheduleRefreshContextAndCandidates()
            return
        }

        // Stock iOS does not accept a longer completion merely because space was
        // pressed. Suggestions are accepted only by tapping them; space commits
        // the literal unless autocorrect replaces a misspelling above.
        textDocumentProxy.insertText(" ")
        lastAutocorrect = nil
        log(kind: .insert, emittedText: " ", rawContext: textDocumentProxy.documentContextBeforeInput)
        returnToLettersAfterSpaceIfNeeded()
        scheduleRefreshContextAndCandidates()
    }

    private func returnToLettersAfterSpaceIfNeeded() {
        guard keyboardView.layoutMode == .numbers || keyboardView.layoutMode == .symbols else {
            return
        }
        let previousLayout = keyboardView.layoutMode
        keyboardView.layoutMode = .letters
        log(
            kind: .layoutChanged,
            rawContext: textDocumentProxy.documentContextBeforeInput,
            metadata: [
                "layout": KeyboardLayoutMode.letters.rawValue,
                "previousLayout": previousLayout.rawValue,
                "reason": "space"
            ]
        )
    }

    private func handleReturn() {
        updateWordContext(from: textDocumentProxy.documentContextBeforeInput ?? "")
        _ = applyAutocorrectIfNeeded(trailing: "", trigger: "return")
        textDocumentProxy.insertText("\n")
        log(kind: .insert, emittedText: "\n", rawContext: textDocumentProxy.documentContextBeforeInput)
        scheduleRefreshContextAndCandidates()
    }

    private func applyAutocorrectIfNeeded(trailing: String, trigger: String) -> Bool {
        guard preferences.autocorrectionEnabled, !currentWord.isEmpty else { return false }
        let candidates = languageDecoder.candidates(for: currentWord, previousWord: previousWord)
        guard let correction = CorrectionFeedbackPolicy.automaticCorrection(
            from: candidates,
            literal: currentWord
        ) else { return false }

        let original = currentWord
        for _ in original {
            textDocumentProxy.deleteBackward()
        }
        textDocumentProxy.insertText(correction.text + trailing)
        lastAutocorrect = (original, correction.text, Date())
        keyboardView.pendingCorrectionDisplay = (original: original, replacement: correction.text)
        log(
            kind: .autocorrectAccepted,
            emittedText: correction.text,
            rawContext: textDocumentProxy.documentContextBeforeInput,
            candidates: candidates,
            selectedCandidate: correction.text,
            metadata: ["literal": original, "trigger": trigger]
        )
        return true
    }

    private func acceptCandidate(_ candidate: String, touch: UITouch?) {
        // Tap the quoted original on the temporary autocorrect chip to revert.
        if let correction = lastAutocorrect,
           candidate == "“\(correction.original)”" || candidate == correction.original {
            revertAutocorrect()
            return
        }
        if let correction = lastAutocorrect, candidate == correction.replacement {
            // Keep the correction; clear the temporary chip.
            lastAutocorrect = nil
            keyboardView.pendingCorrectionDisplay = nil
            return
        }

        let literal = currentWord
        for _ in literal {
            textDocumentProxy.deleteBackward()
        }
        textDocumentProxy.insertText(candidate + " ")
        lastAutocorrect = nil
        keyboardView.pendingCorrectionDisplay = nil
        log(
            kind: .suggestionAccepted,
            emittedText: candidate,
            rawContext: textDocumentProxy.documentContextBeforeInput,
            touch: touch,
            frame: keyboardView.candidateFrame(for: candidate),
            selectedCandidate: candidate,
            metadata: ["literal": literal]
        )
        scheduleRefreshContextAndCandidates()
    }

    private func revertAutocorrect() {
        guard let autocorrect = lastAutocorrect else { return }
        let contextBefore = textDocumentProxy.documentContextBeforeInput
        let suffixHasSpace = contextBefore?.hasSuffix("\(autocorrect.replacement) ") == true
        let deleteCount = autocorrect.replacement.count + (suffixHasSpace ? 1 : 0)
        for _ in 0..<deleteCount {
            textDocumentProxy.deleteBackward()
        }
        textDocumentProxy.insertText(autocorrect.original)
        log(
            kind: .autocorrectReverted,
            emittedText: autocorrect.original,
            rawContext: textDocumentProxy.documentContextBeforeInput,
            metadata: ["reverted": autocorrect.replacement, "source": "chip"]
        )
        lastAutocorrect = nil
        keyboardView.pendingCorrectionDisplay = nil
        scheduleRefreshContextAndCandidates()
    }

    private func showEmojiPage(_ show: Bool) {
        keyboardView.isHidden = show
        emojiView.isHidden = !show
        if show {
            emojiView.reloadCategories()
        }
        log(
            kind: .layoutChanged,
            rawContext: textDocumentProxy.documentContextBeforeInput,
            metadata: ["layout": show ? "emoji" : "letters"]
        )
    }

    private func log(
        kind: KeyboardEventKind,
        key: String? = nil,
        emittedText: String? = nil,
        rawContext: String? = nil,
        touch: UITouch? = nil,
        frame: CGRect? = nil,
        candidates: [DecoderCandidate]? = nil,
        selectedCandidate: String? = nil,
        latencyMilliseconds: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        let point = touch?.location(in: keyboardView)
        let precisePoint = touch?.preciseLocation(in: keyboardView)
        EncryptedEventLedger.shared.append(
            KeyboardResearchEvent(
                sessionID: sessionID,
                kind: kind,
                layout: emojiView.isHidden ? keyboardView.layoutMode : .emoji,
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
                candidates: candidates,
                selectedCandidate: selectedCandidate,
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
            haptic.impactOccurred()
            handleText(text, touch: touch)
        case .shift:
            haptic.impactOccurred()
            switch view.shiftState {
            case .off: view.shiftState = .once
            case .once: view.shiftState = preferences.capsLockEnabled ? .locked : .off
            case .locked: view.shiftState = .off
            }
        case .delete:
            handleDelete()
        case .deleteWord:
            handleDeleteWord()
        case .space:
            handleSpace()
        case .returnKey:
            handleReturn()
        case .changeLayout(let mode):
            if mode == .emoji {
                showEmojiPage(true)
            } else {
                view.layoutMode = mode
                log(
                    kind: .layoutChanged,
                    rawContext: textDocumentProxy.documentContextBeforeInput,
                    metadata: ["layout": mode.rawValue]
                )
            }
        case .nextKeyboard:
            advanceToNextInputMode()
        case .candidate(let candidate):
            haptic.impactOccurred()
            acceptCandidate(candidate, touch: touch)
        case .setOneHanded(let mode):
            preferences.oneHandedMode = mode
            view.oneHandedMode = mode
            log(
                kind: .layoutChanged,
                rawContext: textDocumentProxy.documentContextBeforeInput,
                metadata: ["oneHanded": mode.rawValue]
            )
        }
    }

    fileprivate func keyboardView(_ view: ResearchKeyboardView, didMoveCursorBy offset: Int) {
        guard offset != 0 else { return }
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        log(
            kind: .cursorMoved,
            rawContext: textDocumentProxy.documentContextBeforeInput,
            metadata: ["offset": String(offset)]
        )
    }

    fileprivate func keyboardView(
        _ view: ResearchKeyboardView,
        didMoveCursorVerticallyBy lines: Int
    ) {
        guard lines != 0 else { return }
        let direction = lines > 0 ? 1 : -1
        for _ in 0..<abs(lines) {
            let offset = verticalCursorOffset(direction: direction, keyboardWidth: view.bounds.width)
            guard offset != 0 else { break }
            textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            log(
                kind: .cursorMoved,
                rawContext: textDocumentProxy.documentContextBeforeInput,
                metadata: [
                    "offset": String(offset),
                    "axis": "vertical",
                    "direction": String(direction)
                ]
            )
        }
    }

    /// Extensions have no cursor geometry API. Prefer explicit line breaks when
    /// available; otherwise approximate a visual line from screen width.
    private func verticalCursorOffset(direction: Int, keyboardWidth: CGFloat) -> Int {
        let before = Array(textDocumentProxy.documentContextBeforeInput ?? "")
        let after = Array(textDocumentProxy.documentContextAfterInput ?? "")
        let currentColumn = before.reversed().prefix { $0 != "\n" }.count

        if direction < 0,
           let currentLineBreak = before.lastIndex(of: "\n") {
            let previousEnd = currentLineBreak
            let previousStart = before[..<previousEnd].lastIndex(of: "\n").map { $0 + 1 } ?? 0
            let previousLength = previousEnd - previousStart
            let target = previousStart + min(currentColumn, previousLength)
            return target - before.count
        }

        if direction > 0,
           let currentLineEnd = after.firstIndex(of: "\n") {
            let nextStart = currentLineEnd + 1
            let nextEnd = after[nextStart...].firstIndex(of: "\n") ?? after.endIndex
            let nextLength = nextEnd - nextStart
            return nextStart + min(currentColumn, nextLength)
        }

        let estimatedCharactersPerLine = max(18, Int((keyboardWidth - 32) / 8.2))
        return direction * estimatedCharactersPerLine
    }
}

extension KeyboardViewController: EmojiKeyboardViewDelegate {
    func emojiKeyboard(
        _ view: EmojiKeyboardView,
        didSelect emoji: String,
        at location: CGPoint,
        keyFrame: CGRect
    ) {
        haptic.impactOccurred()
        textDocumentProxy.insertText(emoji)
        log(
            kind: .touch,
            key: emoji,
            emittedText: emoji,
            rawContext: textDocumentProxy.documentContextBeforeInput,
            frame: keyFrame,
            metadata: ["source": "emoji", "touchX": String(Double(location.x)), "touchY": String(Double(location.y))]
        )
        scheduleRefreshContextAndCandidates()
    }

    func emojiKeyboardDidTapLetters(_ view: EmojiKeyboardView) {
        keyboardView.layoutMode = .letters
        showEmojiPage(false)
    }

    func emojiKeyboardDidTapDelete(_ view: EmojiKeyboardView) {
        handleDelete()
    }

    func emojiKeyboardDidTapGlobe(_ view: EmojiKeyboardView) {
        advanceToNextInputMode()
    }
}

// MARK: - Keyboard view

private final class ResearchKeyboardView: UIView {
    enum ShiftState {
        case off
        case once
        case locked
    }

    weak var delegate: ResearchKeyboardViewDelegate?
    var candidates: [String] = [] { didSet { relayoutIfChanged(oldValue != candidates) } }
    /// Temporary autocorrect underline chip (original ↔ replacement).
    var pendingCorrectionDisplay: (original: String, replacement: String)? {
        didSet {
            setNeedsLayout()
            setNeedsDisplay()
        }
    }
    var layoutMode: KeyboardLayoutMode = .letters { didSet { relayoutIfChanged(oldValue != layoutMode) } }
    var shiftState: ShiftState = .off { didSet { if oldValue != shiftState { setNeedsDisplay() } } }
    var needsInputModeSwitchKey = true {
        didSet { relayoutIfChanged(oldValue != needsInputModeSwitchKey) }
    }
    var recordingActive = false { didSet { if oldValue != recordingActive { setNeedsDisplay() } } }
    var returnLabel = "return" { didSet { relayoutIfChanged(oldValue != returnLabel) } }
    var returnKeyIsPrimary = false {
        didSet { if oldValue != returnKeyIsPrimary { setNeedsDisplay() } }
    }
    var characterPreviewEnabled = true
    var capsLockEnabled = true
    var showsCandidateBar = true { didSet { relayoutIfChanged(oldValue != showsCandidateBar) } }
    var isLandscape = false { didSet { relayoutIfChanged(oldValue != isLandscape) } }
    var deviceClassScale: CGFloat = 0.5 {
        didSet { relayoutIfChanged(abs(oldValue - deviceClassScale) > 0.001) }
    }
    var oneHandedMode: OneHandedMode = .off { didSet { relayoutIfChanged(oldValue != oneHandedMode) } }
    var isUppercase: Bool { shiftState != .off }

    private var renderedKeys: [RenderedKey] = []
    private var candidateFrames: [(String, CGRect)] = []
    private var expandFrame: CGRect?
    private var activeTouch: UITouch?
    private var secondaryTouchActions: [ObjectIdentifier: KeyboardAction] = [:]
    private var activeAction: KeyboardAction?
    private var previewKey: RenderedKey?
    private var alternatesKey: RenderedKey?
    private var alternateOptions: [String] = []
    private var alternateFrames: [CGRect] = []
    private var selectedAlternate = 0
    private var oneHandedMenuFrames: [(OneHandedMode, CGRect)] = []
    private var showsOneHandedMenu = false
    private var trackpadOrigin: CGPoint?
    private var trackpadHorizontalRemainder: CGFloat = 0
    private var trackpadVerticalRemainder: CGFloat = 0
    private var isTrackpadActive = false
    private var longPressTimer: Timer?
    private var deleteTimer: Timer?
    private var deleteRepeatCount = 0
    private var didRepeatDelete = false
    private var momentaryLayoutOrigin: KeyboardLayoutMode?
    private var didSlideFromLayoutKey = false

    private var candidateBarHeight: CGFloat {
        guard showsCandidateBar else { return 0 }
        return isLandscape
            ? (32 + deviceClassScale * 3)
            : (40 + deviceClassScale * 4)
    }

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private func relayoutIfChanged(_ changed: Bool) {
        guard changed else { return }
        setNeedsLayout()
        setNeedsDisplay()
    }

    func keyFrame(at point: CGPoint) -> CGRect? {
        keyAt(point)?.frame
    }

    func candidateFrame(for text: String) -> CGRect? {
        candidateFrames.first(where: { $0.0 == text })?.1
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1)
                : UIColor(red: 0.82, green: 0.835, blue: 0.86, alpha: 1)
        }
        haptic.prepare()
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
        if isTrackpadActive {
            drawTrackpad(context)
            return
        }
        drawCandidateBar(context)
        for key in renderedKeys {
            draw(key: key, context: context)
        }
        if let expandFrame {
            drawExpandHandle(expandFrame, context: context)
        }
        if alternatesKey != nil {
            drawAlternates(context)
        } else if let previewKey {
            drawPopup(for: previewKey, context: context)
        }
        if showsOneHandedMenu {
            drawOneHandedMenu(context)
        }
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let activeTouch {
            for touch in touches where touch !== activeTouch {
                updateSecondaryTouch(touch)
            }
            return
        }

        guard let touch = touches.first else { return }
        activeTouch = touch
        for secondary in touches where secondary !== touch {
            updateSecondaryTouch(secondary)
        }
        let point = touch.location(in: self)

        if showsOneHandedMenu {
            if let hit = oneHandedMenuFrames.first(where: { $0.1.contains(point) }) {
                showsOneHandedMenu = false
                activeAction = .setOneHanded(hit.0)
            } else {
                showsOneHandedMenu = false
                activeAction = nil
            }
            setNeedsDisplay()
            return
        }

        if let expandFrame, expandFrame.contains(point) {
            activeAction = .setOneHanded(.off)
            setNeedsDisplay()
            return
        }

        if let candidate = candidateFrames.first(where: { $0.1.contains(point) }) {
            activeAction = .candidate(candidate.0)
            previewKey = nil
            setNeedsDisplay()
            return
        }

        guard let key = keyAt(point) else {
            activeAction = nil
            previewKey = nil
            setNeedsDisplay()
            return
        }

        activeAction = key.action
        updatePreview(for: key)

        // iOS momentary layout gesture: hold 123 / #+=, slide to a symbol,
        // release to insert it, then return to the originating layout.
        if case .changeLayout(let target) = key.action, target != .emoji {
            momentaryLayoutOrigin = layoutMode
            didSlideFromLayoutKey = false
            layoutMode = target
            rebuildLayout()
            haptic.impactOccurred(intensity: 0.45)
            setNeedsDisplay()
            return
        }

        scheduleLongPress(for: key)

        if key.action == .space {
            trackpadOrigin = point
        } else if key.action == .delete {
            didRepeatDelete = false
            deleteRepeatCount = 0
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
                self?.beginDeleteRepeat()
            }
        }
        if showsPopup(for: key.action) {
            haptic.impactOccurred(intensity: 0.6)
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch !== activeTouch {
            updateSecondaryTouch(touch)
        }
        guard let activeTouch, touches.contains(activeTouch) else { return }
        let touch = activeTouch
        let point = touch.location(in: self)

        if alternatesKey != nil {
            let index = alternateFrames.firstIndex { $0.insetBy(dx: -4, dy: -20).contains(point) }
            if let index, index != selectedAlternate {
                selectedAlternate = index
                haptic.impactOccurred(intensity: 0.4)
                setNeedsDisplay()
            }
            return
        }

        if isTrackpadActive {
            guard let origin = trackpadOrigin else { return }
            trackpadHorizontalRemainder += point.x - origin.x
            trackpadVerticalRemainder += point.y - origin.y
            trackpadOrigin = point

            let horizontalStep: CGFloat = 4.5
            let horizontalCharacters = Int(trackpadHorizontalRemainder / horizontalStep)
            if horizontalCharacters != 0 {
                delegate?.keyboardView(self, didMoveCursorBy: horizontalCharacters)
                trackpadHorizontalRemainder -= CGFloat(horizontalCharacters) * horizontalStep
            }

            let verticalStep: CGFloat = 18
            let verticalLines = Int(trackpadVerticalRemainder / verticalStep)
            if verticalLines != 0 {
                delegate?.keyboardView(self, didMoveCursorVerticallyBy: verticalLines)
                trackpadVerticalRemainder -= CGFloat(verticalLines) * verticalStep
            }
            return
        }

        if momentaryLayoutOrigin != nil {
            if let key = keyAt(point), isTextAction(key.action) {
                if activeAction != key.action {
                    activeAction = key.action
                    didSlideFromLayoutKey = true
                    updatePreview(for: key)
                    haptic.impactOccurred(intensity: 0.35)
                    setNeedsDisplay()
                }
            }
            return
        }

        if case .space = activeAction {
            // Moving before the hold completes must not cancel trackpad entry.
            // Keep following the finger so activation begins without a jump.
            trackpadOrigin = point
            return
        }

        // Slide to a neighboring character key, moving the preview with the finger.
        guard isTextAction(activeAction), let key = keyAt(point), isTextAction(key.action) else { return }
        if activeAction != key.action {
            activeAction = key.action
            updatePreview(for: key)
            cancelLongPress()
            scheduleLongPress(for: key)
            haptic.impactOccurred(intensity: 0.4)
            setNeedsDisplay()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch !== activeTouch {
            let identifier = ObjectIdentifier(touch)
            if let action = secondaryTouchActions.removeValue(forKey: identifier) {
                UIDevice.current.playInputClick()
                delegate?.keyboardView(self, didTrigger: action, touch: touch)
            }
        }
        guard let activeTouch, touches.contains(activeTouch) else { return }
        cancelLongPress()
        deleteTimer?.invalidate()
        deleteTimer = nil

        if alternatesKey != nil, selectedAlternate < alternateOptions.count {
            let option = alternateOptions[selectedAlternate]
            let touch = activeTouch
            clearAlternates()
            clearTouch()
            UIDevice.current.playInputClick()
            delegate?.keyboardView(self, didTrigger: .text(option), touch: touch)
            setNeedsDisplay()
            return
        }

        defer {
            clearTouch()
            setNeedsDisplay()
        }

        if isTrackpadActive {
            isTrackpadActive = false
            return
        }
        guard let action = activeAction else { return }

        if let origin = momentaryLayoutOrigin {
            if didSlideFromLayoutKey, isTextAction(action) {
                UIDevice.current.playInputClick()
                delegate?.keyboardView(self, didTrigger: action, touch: activeTouch)
                layoutMode = origin
                rebuildLayout()
            } else {
                UIDevice.current.playInputClick()
                delegate?.keyboardView(self, didTrigger: action, touch: activeTouch)
            }
            // A simple tap leaves the newly selected layout active.
            return
        }

        if action == .delete, didRepeatDelete { return }

        UIDevice.current.playInputClick()
        delegate?.keyboardView(self, didTrigger: action, touch: activeTouch)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            secondaryTouchActions.removeValue(forKey: ObjectIdentifier(touch))
        }
        guard let activeTouch, touches.contains(activeTouch) else { return }
        cancelLongPress()
        deleteTimer?.invalidate()
        if let origin = momentaryLayoutOrigin {
            layoutMode = origin
            rebuildLayout()
        }
        clearAlternates()
        clearTouch()
        setNeedsDisplay()
    }

    private func clearTouch() {
        activeTouch = nil
        activeAction = nil
        previewKey = nil
        trackpadOrigin = nil
        trackpadHorizontalRemainder = 0
        trackpadVerticalRemainder = 0
        isTrackpadActive = false
        didRepeatDelete = false
        deleteRepeatCount = 0
        momentaryLayoutOrigin = nil
        didSlideFromLayoutKey = false
    }

    private func clearAlternates() {
        alternatesKey = nil
        alternateOptions = []
        alternateFrames = []
        selectedAlternate = 0
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func scheduleLongPress(for key: RenderedKey) {
        cancelLongPress()
        let needsTimer = key.action == .space
            || key.action == .nextKeyboard
            || !alternates(for: key).isEmpty
        guard needsTimer else { return }
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.handleLongPress(on: key)
        }
    }

    private func handleLongPress(on key: RenderedKey) {
        switch key.action {
        case .space:
            isTrackpadActive = true
            if let activeTouch {
                trackpadOrigin = activeTouch.location(in: self)
            }
            trackpadHorizontalRemainder = 0
            trackpadVerticalRemainder = 0
            haptic.impactOccurred(intensity: 0.8)
        case .nextKeyboard:
            showsOneHandedMenu = true
            // Releasing the finger should leave the menu open, not switch keyboards.
            activeAction = nil
            previewKey = nil
            haptic.impactOccurred(intensity: 0.8)
        default:
            let options = alternates(for: key)
            guard !options.isEmpty else { return }
            alternatesKey = key
            alternateOptions = options
            selectedAlternate = 0
            previewKey = nil
            haptic.impactOccurred(intensity: 0.8)
        }
        setNeedsDisplay()
    }

    private func beginDeleteRepeat() {
        didRepeatDelete = true
        deleteRepeatCount = 0
        performDeleteRepeatTick()
    }

    private func performDeleteRepeatTick() {
        guard activeAction == .delete, activeTouch != nil else { return }
        deleteRepeatCount += 1

        let action: KeyboardAction
        let nextInterval: TimeInterval
        switch deleteRepeatCount {
        case 1...6:
            action = .delete
            nextInterval = 0.10
        case 7...16:
            action = .delete
            nextInterval = 0.065
        default:
            action = .deleteWord
            nextInterval = 0.18
        }
        delegate?.keyboardView(self, didTrigger: action, touch: activeTouch)
        deleteTimer = Timer.scheduledTimer(withTimeInterval: nextInterval, repeats: false) {
            [weak self] _ in
            self?.performDeleteRepeatTick()
        }
    }

    /// Track overlapping thumb taps independently and emit on release, preserving
    /// normal typing order instead of inserting secondary taps on touch-down.
    private func updateSecondaryTouch(_ touch: UITouch) {
        let point = touch.location(in: self)
        if let candidate = candidateFrames.first(where: { $0.1.contains(point) }) {
            secondaryTouchActions[ObjectIdentifier(touch)] = .candidate(candidate.0)
            return
        }
        guard let key = keyAt(point) else {
            secondaryTouchActions.removeValue(forKey: ObjectIdentifier(touch))
            return
        }
        switch key.action {
        case .text, .space, .delete, .returnKey:
            secondaryTouchActions[ObjectIdentifier(touch)] = key.action
        default:
            secondaryTouchActions.removeValue(forKey: ObjectIdentifier(touch))
        }
    }

    private func keyAt(_ point: CGPoint) -> RenderedKey? {
        renderedKeys.first(where: { $0.frame.insetBy(dx: -2, dy: -4).contains(point) })
    }

    private func isTextAction(_ action: KeyboardAction?) -> Bool {
        guard let action else { return false }
        if case .text = action { return true }
        return false
    }

    private func showsPopup(for action: KeyboardAction) -> Bool {
        guard characterPreviewEnabled, case .text(let text) = action else { return false }
        return text.count == 1
    }

    private func updatePreview(for key: RenderedKey) {
        previewKey = showsPopup(for: key.action) ? key : nil
    }

    private func alternates(for key: RenderedKey) -> [String] {
        guard case .text(let text) = key.action else { return [] }
        let base = isUppercase && text.first?.isLetter == true ? text.uppercased() : text
        return KeyAlternates.alternates(for: base)
    }

    // MARK: Layout

    private var contentRect: CGRect {
        switch oneHandedMode {
        case .off:
            return bounds
        case .left, .right:
            let width = bounds.width * 0.82
            let x = oneHandedMode == .left ? 0 : bounds.width - width
            return CGRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    private func rebuildLayout() {
        renderedKeys.removeAll(keepingCapacity: true)
        candidateFrames.removeAll(keepingCapacity: true)
        expandFrame = nil

        let content = contentRect
        let t = deviceClassScale
        // Scale key spacing with device class so proportions stay iOS-like.
        let side: CGFloat = isLandscape ? (2.5 + t * 0.8) : (3 + t * 1.2)
        let gap: CGFloat = isLandscape ? (4.2 + t * 1.1) : (5.2 + t * 1.6)
        let rowGap: CGFloat = isLandscape ? (6.0 + t * 1.6) : (9.0 + t * 2.8)
        let bottomPad: CGFloat = isLandscape ? 2.5 : 4
        let availableHeight = content.height - candidateBarHeight - bottomPad
        let minRow: CGFloat = isLandscape ? 31.5 : 39
        let maxRow: CGFloat = isLandscape ? 42 : 52
        let proposedRow = (availableHeight - rowGap * 3) / 4
        let rowHeight = Swift.min(maxRow, Swift.max(minRow, proposedRow))
        let top = candidateBarHeight + (isLandscape ? 4.5 : 7)

        let rows: [[(String, KeyboardAction, CGFloat, Bool)]]
        switch layoutMode {
        case .letters, .emoji:
            rows = [
                Array("qwertyuiop").map { (String($0), .text(String($0)), 1, false) },
                Array("asdfghjkl").map { (String($0), .text(String($0)), 1, false) },
                [("shift", .shift, 1.5, true)]
                    + Array("zxcvbnm").map { (String($0), .text(String($0)), 1, false) }
                    + [("delete", .delete, 1.5, true)],
                bottomRow(letterMode: true)
            ]
        case .numbers:
            rows = [
                Array("1234567890").map { (String($0), .text(String($0)), 1, false) },
                Array("-/:;()$&@\"").map { (String($0), .text(String($0)), 1, false) },
                [("#+=", .changeLayout(.symbols), 1.5, true)]
                    + Array(".,?!'").map { (String($0), .text(String($0)), 1, false) }
                    + [("delete", .delete, 1.5, true)],
                bottomRow(letterMode: false)
            ]
        case .symbols:
            rows = [
                Array("[]{}#%^*+=").map { (String($0), .text(String($0)), 1, false) },
                Array("_\\|~<>€£¥•").map { (String($0), .text(String($0)), 1, false) },
                [("123", .changeLayout(.numbers), 1.5, true)]
                    + Array(".,?!'").map { (String($0), .text(String($0)), 1, false) }
                    + [("delete", .delete, 1.5, true)],
                bottomRow(letterMode: false)
            ]
        }

        for (rowIndex, row) in rows.enumerated() {
            let y = top + CGFloat(rowIndex) * (rowHeight + rowGap)
            let totalUnits = row.reduce(0) { $0 + $1.2 }
            let available = content.width - side * 2 - gap * CGFloat(max(0, row.count - 1))
            let unitWidth = available / totalUnits
            var x = content.minX + side
            // The home row sits inset from the edges on iOS.
            if layoutMode != .numbers, layoutMode != .symbols, rowIndex == 1 {
                let rowWidth = unitWidth * totalUnits + gap * CGFloat(max(0, row.count - 1))
                x = content.minX + (content.width - rowWidth) / 2
            }
            for item in row {
                let width = unitWidth * item.2
                renderedKeys.append(
                    RenderedKey(
                        label: item.0,
                        action: item.1,
                        frame: CGRect(x: x, y: y, width: width, height: rowHeight),
                        isSpecial: item.3
                    )
                )
                x += width + gap
            }
        }

        if showsCandidateBar {
            if let correction = pendingCorrectionDisplay {
                // Preserve the three QuickType slots during correction feedback.
                var items = ["“\(correction.original)”", correction.replacement]
                if let third = candidates.first(where: {
                    $0 != correction.original && $0 != correction.replacement
                }) {
                    items.append(third)
                }
                let candidateWidth = content.width / CGFloat(items.count)
                candidateFrames = items.enumerated().map {
                    ($0.element, CGRect(
                        x: content.minX + CGFloat($0.offset) * candidateWidth,
                        y: 0,
                        width: candidateWidth,
                        height: candidateBarHeight
                    ))
                }
            } else if !candidates.isEmpty {
                let count = CGFloat(candidates.count)
                let candidateWidth = content.width / count
                candidateFrames = candidates.enumerated().map {
                    ($0.element, CGRect(
                        x: content.minX + CGFloat($0.offset) * candidateWidth,
                        y: 0,
                        width: candidateWidth,
                        height: candidateBarHeight
                    ))
                }
            }
        }

        if oneHandedMode != .off {
            let stripWidth = bounds.width - content.width
            let x = oneHandedMode == .left ? content.maxX : 0
            expandFrame = CGRect(
                x: x + (stripWidth - 38) / 2,
                y: bounds.midY - 19,
                width: 38,
                height: 38
            )
        }

        rebuildAccessibilityElements()
    }

    private func bottomRow(letterMode: Bool) -> [(String, KeyboardAction, CGFloat, Bool)] {
        var row: [(String, KeyboardAction, CGFloat, Bool)] = [
            (letterMode ? "123" : "ABC", .changeLayout(letterMode ? .numbers : .letters), 1.3, true)
        ]
        if needsInputModeSwitchKey {
            row.append(("globe", .nextKeyboard, 1.0, true))
        }
        row.append(("emoji", .changeLayout(.emoji), 1.0, true))
        row.append(("space", .space, needsInputModeSwitchKey ? 4.0 : 4.8, false))
        row.append((returnLabel, .returnKey, 1.7, true))
        return row
    }

    // MARK: Colors

    private var letterKeyFill: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1)
                : .white
        }
    }

    private var specialKeyFill: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 1)
                : UIColor(red: 0.675, green: 0.70, blue: 0.74, alpha: 1)
        }
    }

    private var keyLabelColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? .white : .black
        }
    }

    // MARK: Drawing

    private func drawCandidateBar(_ context: CGContext) {
        guard showsCandidateBar else {
            if recordingActive {
                UIColor.systemRed.setFill()
                context.fillEllipse(in: CGRect(x: bounds.width - 11, y: 4, width: 5, height: 5))
            }
            return
        }
        let bar = CGRect(x: 0, y: 0, width: bounds.width, height: candidateBarHeight)
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.14, green: 0.14, blue: 0.15, alpha: 1)
                : UIColor(red: 0.82, green: 0.835, blue: 0.86, alpha: 1)
        }.setFill()
        context.fill(bar)

        for (index, candidate) in candidateFrames.enumerated() {
            if index > 0 {
                UIColor.separator.setStroke()
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: candidate.1.minX, y: 10))
                context.addLine(to: CGPoint(x: candidate.1.minX, y: candidateBarHeight - 10))
                context.strokePath()
            }
            let isActive: Bool = {
                if case .candidate(let text) = activeAction { return text == candidate.0 }
                return false
            }()
            if isActive {
                UIColor.label.withAlphaComponent(0.1).setFill()
                UIBezierPath(roundedRect: candidate.1.insetBy(dx: 2, dy: 4), cornerRadius: 5).fill()
            }

            let isCorrectionReplacement = pendingCorrectionDisplay?.replacement == candidate.0

            if isCorrectionReplacement {
                // Temporary gray/blue outline under the autocorrected word.
                drawText(
                    candidate.0,
                    in: candidate.1,
                    font: .systemFont(ofSize: 17, weight: .medium),
                    color: keyLabelColor
                )
                let textWidth = (candidate.0 as NSString).size(
                    withAttributes: [.font: UIFont.systemFont(ofSize: 17, weight: .medium)]
                ).width
                let underline = CGRect(
                    x: candidate.1.midX - textWidth / 2,
                    y: candidate.1.midY + 10,
                    width: textWidth,
                    height: 2.5
                )
                UIColor.secondaryLabel.setFill()
                UIBezierPath(roundedRect: underline, cornerRadius: 1.2).fill()
            } else {
                drawText(
                    candidate.0,
                    in: candidate.1,
                    font: .systemFont(ofSize: 17),
                    color: keyLabelColor
                )
            }
        }

        if recordingActive {
            UIColor.systemRed.setFill()
            context.fillEllipse(in: CGRect(x: bounds.width - 11, y: 6, width: 5, height: 5))
        }
    }

    private func draw(key: RenderedKey, context: CGContext) {
        let isActive = activeAction == key.action && alternatesKey == nil
        let isPrimaryReturn = key.action == .returnKey && returnKeyIsPrimary
        let isEngagedShift = key.action == .shift && shiftState != .off
        let base: UIColor
        if isPrimaryReturn {
            base = UIColor.systemBlue
        } else if isEngagedShift {
            base = letterKeyFill
        } else if key.isSpecial || key.action == .space {
            base = specialKeyFill
        } else {
            base = letterKeyFill
        }
        let fill = isActive
            ? (traitCollection.userInterfaceStyle == .dark
               ? base.withAlphaComponent(0.55)
               : base == UIColor.systemBlue
                 ? base.withAlphaComponent(0.75)
                 : UIColor(white: 0.78, alpha: 1))
            : base
        fill.setFill()
        let path = UIBezierPath(roundedRect: key.frame, cornerRadius: 5.5)
        path.fill()

        if traitCollection.userInterfaceStyle != .dark, !isActive, !isPrimaryReturn {
            UIColor.black.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 0.4
            path.stroke()
        }

        let tint: UIColor = isPrimaryReturn ? .white : keyLabelColor
        if let symbol = symbolName(for: key) {
            drawSymbol(
                symbol,
                in: key.frame,
                pointSize: isLandscape ? 17 : 19,
                tint: tint
            )
            return
        }

        let label = displayLabel(for: key)
        let fontSize: CGFloat
        if case .text = key.action, label.count == 1 {
            fontSize = isLandscape ? 19 : 22
        } else {
            fontSize = isLandscape ? 14 : 15
        }
        drawText(label, in: key.frame, font: .systemFont(ofSize: fontSize), color: tint)
    }

    private func symbolName(for key: RenderedKey) -> String? {
        switch key.action {
        case .delete:
            return "delete.left"
        case .shift:
            switch shiftState {
            case .off: return "shift"
            case .once: return "shift.fill"
            case .locked: return "capslock.fill"
            }
        case .nextKeyboard:
            return "globe"
        case .changeLayout(.emoji):
            return "face.smiling"
        default:
            return nil
        }
    }

    private func drawSymbol(_ name: String, in rect: CGRect, pointSize: CGFloat, tint: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .light)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(tint, renderingMode: .alwaysOriginal) else { return }
        let origin = CGPoint(
            x: rect.midX - image.size.width / 2,
            y: rect.midY - image.size.height / 2
        )
        image.draw(at: origin)
    }

    private func displayLabel(for key: RenderedKey) -> String {
        if case .text = key.action, isUppercase {
            return key.label.uppercased()
        }
        return key.label
    }

    private func drawPopup(for key: RenderedKey, context: CGContext) {
        let label = displayLabel(for: key)
        let keyFrame = key.frame
        let popupWidth = max(keyFrame.width + 14, 46)
        let popupHeight: CGFloat = isLandscape ? 44 : 56
        let popupX = min(max(keyFrame.midX - popupWidth / 2, 2), bounds.width - popupWidth - 2)
        let popupY = max(keyFrame.minY - popupHeight - 6, candidateBarHeight + 2)
        let popupRect = CGRect(x: popupX, y: popupY, width: popupWidth, height: popupHeight)

        let bubble = UIBezierPath(roundedRect: popupRect, cornerRadius: 10)
        let stemWidth = min(keyFrame.width * 0.85, popupWidth - 8)
        let stem = UIBezierPath(
            roundedRect: CGRect(
                x: keyFrame.midX - stemWidth / 2,
                y: popupRect.maxY - 8,
                width: stemWidth,
                height: keyFrame.minY - (popupRect.maxY - 8) + 2
            ),
            cornerRadius: 6
        )
        bubble.append(stem)

        letterKeyFill.setFill()
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 2),
            blur: 4,
            color: UIColor.black.withAlphaComponent(0.25).cgColor
        )
        bubble.fill()
        context.restoreGState()
        UIColor.black.withAlphaComponent(0.18).setStroke()
        bubble.lineWidth = 0.5
        bubble.stroke()

        drawText(
            label,
            in: popupRect.insetBy(dx: 0, dy: -2),
            font: .systemFont(ofSize: isLandscape ? 22 : 28),
            color: keyLabelColor
        )
    }

    private func drawAlternates(_ context: CGContext) {
        guard let key = alternatesKey, !alternateOptions.isEmpty else { return }
        let itemWidth: CGFloat = 42
        let itemHeight: CGFloat = isLandscape ? 40 : 48
        let panelWidth = itemWidth * CGFloat(alternateOptions.count) + 10
        let panelX = min(max(key.frame.midX - panelWidth / 2, 3), bounds.width - panelWidth - 3)
        let panelY = max(key.frame.minY - itemHeight - 12, 2)
        let panel = CGRect(x: panelX, y: panelY, width: panelWidth, height: itemHeight + 10)

        letterKeyFill.setFill()
        let path = UIBezierPath(roundedRect: panel, cornerRadius: 10)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 2),
            blur: 5,
            color: UIColor.black.withAlphaComponent(0.3).cgColor
        )
        path.fill()
        context.restoreGState()

        alternateFrames = alternateOptions.enumerated().map { index, _ in
            CGRect(
                x: panel.minX + 5 + CGFloat(index) * itemWidth,
                y: panel.minY + 5,
                width: itemWidth,
                height: itemHeight
            )
        }

        for (index, option) in alternateOptions.enumerated() {
            let frame = alternateFrames[index]
            if index == selectedAlternate {
                UIColor.systemBlue.setFill()
                UIBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), cornerRadius: 7).fill()
            }
            drawText(
                option,
                in: frame,
                font: .systemFont(ofSize: 24),
                color: index == selectedAlternate ? .white : keyLabelColor
            )
        }
    }

    private func drawOneHandedMenu(_ context: CGContext) {
        let options: [(OneHandedMode, String)] = [
            (.left, "Left"),
            (.off, "Full"),
            (.right, "Right")
        ]
        let itemHeight: CGFloat = 38
        let panelWidth: CGFloat = 140
        let panelHeight = itemHeight * CGFloat(options.count) + 8
        let panel = CGRect(
            x: 8,
            y: max(bounds.height - panelHeight - 60, candidateBarHeight + 4),
            width: panelWidth,
            height: panelHeight
        )

        letterKeyFill.setFill()
        let path = UIBezierPath(roundedRect: panel, cornerRadius: 12)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 2),
            blur: 6,
            color: UIColor.black.withAlphaComponent(0.3).cgColor
        )
        path.fill()
        context.restoreGState()

        oneHandedMenuFrames = options.enumerated().map { index, option in
            let frame = CGRect(
                x: panel.minX + 4,
                y: panel.minY + 4 + CGFloat(index) * itemHeight,
                width: panel.width - 8,
                height: itemHeight
            )
            return (option.0, frame)
        }

        for (index, option) in options.enumerated() {
            let frame = oneHandedMenuFrames[index].1
            if option.0 == oneHandedMode {
                UIColor.systemBlue.withAlphaComponent(0.15).setFill()
                UIBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), cornerRadius: 8).fill()
            }
            drawText(
                option.1,
                in: frame,
                font: .systemFont(ofSize: 16),
                color: keyLabelColor
            )
        }
    }

    private func drawExpandHandle(_ frame: CGRect, context: CGContext) {
        specialKeyFill.setFill()
        UIBezierPath(roundedRect: frame, cornerRadius: frame.width / 2).fill()
        drawText(
            oneHandedMode == .left ? "›" : "‹",
            in: frame,
            font: .systemFont(ofSize: 22, weight: .semibold),
            color: keyLabelColor
        )
    }

    private func drawTrackpad(_ context: CGContext) {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1)
                : UIColor(red: 0.88, green: 0.89, blue: 0.91, alpha: 1)
        }.setFill()
        context.fill(bounds)
        drawText(
            "Slide to move cursor",
            in: bounds,
            font: .systemFont(ofSize: 15),
            color: .secondaryLabel
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
        for candidate in candidateFrames {
            let element = KeyboardAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = "Suggestion \(candidate.0)"
            element.accessibilityFrameInContainerSpace = candidate.1
            element.accessibilityTraits = .keyboardKey
            element.activation = { [weak self] in
                guard let self else { return }
                self.delegate?.keyboardView(self, didTrigger: .candidate(candidate.0), touch: nil)
            }
            elements.append(element)
        }
        for key in renderedKeys {
            let element = KeyboardAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = accessibilityLabel(for: key)
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

    private func accessibilityLabel(for key: RenderedKey) -> String {
        switch key.action {
        case .delete: return "Delete"
        case .shift: return shiftState == .locked ? "Caps lock" : "Shift"
        case .space: return "Space"
        case .returnKey: return returnLabel
        case .nextKeyboard: return "Next keyboard"
        case .changeLayout(.emoji): return "Emoji"
        default: return displayLabel(for: key)
        }
    }
}

extension ResearchKeyboardView: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
