import SwiftUI
import UIKit

enum InAppKeyboardEditKind {
    case insert
    case delete
    case replace
}

struct InAppKeyboardEdit {
    let kind: InAppKeyboardEditKind
    let originalText: String
    let emittedText: String
    let source: EditSource
    let gesture: TouchGesture?
    let selectedKeyFrame: CGRect?
    let tapInfo: TapInfo
    /// Top suggestion-bar texts visible when this edit happened.
    let suggestionsOffered: [String]
    /// Suggestion/autocorrect text chosen for this edit, if any.
    let selectedSuggestion: String?
}

struct InAppResearchKeyboardView: UIViewRepresentable {
    /// Key rows + QuickType bar + home-indicator strip (globe / mic icons).
    static var preferredHeight: CGFloat {
        SystemKeyboardMetrics.totalDockedHeight()
    }

    let text: String
    @Binding var caretUTF16: Int
    @Binding var selectionLengthUTF16: Int
    let onEdits: ([InAppKeyboardEdit]) -> Void

    init(
        text: String,
        caretUTF16: Binding<Int>,
        selectionLengthUTF16: Binding<Int> = .constant(0),
        onEdits: @escaping ([InAppKeyboardEdit]) -> Void
    ) {
        self.text = text
        self._caretUTF16 = caretUTF16
        self._selectionLengthUTF16 = selectionLengthUTF16
        self.onEdits = onEdits
    }

    func makeUIView(context: Context) -> InAppResearchKeyboard {
        SystemKeyboardMetrics.ensureMeasured()
        let keyboard = InAppResearchKeyboard()
        keyboard.onEdits = onEdits
        keyboard.onSelectionChange = { caret, length in
            caretUTF16 = caret
            selectionLengthUTF16 = length
        }
        keyboard.syncExternalText(
            text,
            caretUTF16: caretUTF16,
            selectionLength: selectionLengthUTF16,
            force: true
        )
        return keyboard
    }

    func updateUIView(_ keyboard: InAppResearchKeyboard, context: Context) {
        keyboard.onEdits = onEdits
        keyboard.onSelectionChange = { caret, length in
            caretUTF16 = caret
            selectionLengthUTF16 = length
        }
        keyboard.syncExternalText(
            text,
            caretUTF16: caretUTF16,
            selectionLength: selectionLengthUTF16,
            force: false
        )
        keyboard.applyDeviceMetrics(keyboardWidth: keyboard.bounds.width)
    }
}

private enum InAppKeyboardAction: Equatable {
    case text(String)
    case shift
    case delete
    case space
    case returnKey
    case globe
    case microphone
    case layout(KeyboardLayoutMode)
    case candidate(String)
}

private struct InAppRenderedKey {
    let label: String
    let action: InAppKeyboardAction
    let frame: CGRect
    let isSpecial: Bool

    var isLetter: Bool {
        guard case .text(let text) = action else { return false }
        return text.count == 1 && text.first?.isLetter == true
    }
}

final class InAppResearchKeyboard: UIView {
    private enum ShiftState {
        case lowercase
        case uppercase
        case capsLock
    }

    var onEdits: (([InAppKeyboardEdit]) -> Void)?
    var onCaretUTF16Change: ((Int) -> Void)?
    var onSelectionChange: ((Int, Int) -> Void)?

    private let decoder = LocalLanguageDecoder()
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private var localText = ""
    private var localCaretUTF16 = 0
    private var localSelectionLength = 0
    private var layoutMode: KeyboardLayoutMode = .letters
    private var shiftState: ShiftState = .lowercase
    private var renderedKeys: [InAppRenderedKey] = []
    private var candidateFrames: [(text: String, frame: CGRect)] = []
    private var candidates: [DecoderCandidate] = []
    private var pendingAutocorrect: DecoderCandidate?

    private var activeTouch: UITouch?
    private var activeAction: InAppKeyboardAction?
    private var activeKey: InAppRenderedKey?
    private var secondaryTouchActions: [ObjectIdentifier: InAppKeyboardAction] = [:]
    private var touchGestures: [ObjectIdentifier: TouchGesture] = [:]
    private var deleteTimer: Timer?
    private var didRepeatDelete = false
    private var deleteRepeatCount = 0
    private var lastShiftTap: TimeInterval = 0

    /// iOS long-press Space → trackpad cursor movement.
    private var spaceTrackpadTimer: Timer?
    private var isSpaceTrackpadActive = false
    private var trackpadLastPoint: CGPoint?
    private var trackpadAccum = CGPoint.zero

    private var layoutSpec = SystemKeyboardMetrics.layoutSpec()
    private var isLandscape: Bool { layoutSpec.isLandscape }
    private var candidateHeight: CGFloat { layoutSpec.candidateBarHeight }
    private var letterFontSize: CGFloat { layoutSpec.letterFontSize }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Fast thumb typing needs concurrent touches; single-touch drops taps.
        isMultipleTouchEnabled = true
        clipsToBounds = false
        isOpaque = true
        backgroundColor = keyboardBackground
        haptic.prepare()
        applyDeviceMetrics()
    }

    func applyDeviceMetrics(keyboardWidth: CGFloat? = nil) {
        let screenBounds = window?.windowScene?.screen.bounds ?? UIScreen.main.bounds
        let scene = window?.windowScene
        let width = (keyboardWidth ?? bounds.width).nonZero
            ?? min(screenBounds.width, screenBounds.height)
        let next = SystemKeyboardMetrics.layoutSpec(
            keyboardWidth: width,
            screenBounds: screenBounds,
            windowScene: scene
        )
        guard next != layoutSpec else { return }
        layoutSpec = next
        setNeedsLayout()
        setNeedsDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        deleteTimer?.invalidate()
    }

    /// Keep parent/SwiftUI text in sync without stomping ahead-of-parent local typing.
    func syncExternalText(_ text: String, caretUTF16: Int, selectionLength: Int = 0, force: Bool) {
        let nsLen = (text as NSString).length
        let clampedCaret = max(0, min(caretUTF16, nsLen))
        let clampedSel = max(0, min(selectionLength, nsLen - clampedCaret))
        if !force {
            if activeTouch != nil || !secondaryTouchActions.isEmpty { return }
            // Same text: accept caret / selection changes from a tap or double-tap.
            if text == localText {
                if clampedCaret != localCaretUTF16 || clampedSel != localSelectionLength {
                    localCaretUTF16 = clampedCaret
                    localSelectionLength = clampedSel
                    refreshCandidates()
                }
                return
            }
            // Parent often lags one or more keystrokes behind during fast typing.
            if localText.hasPrefix(text), localText.count >= text.count {
                return
            }
        }
        if text == localText,
           clampedCaret == localCaretUTF16,
           clampedSel == localSelectionLength {
            return
        }
        localText = text
        localCaretUTF16 = clampedCaret
        localSelectionLength = clampedSel
        refreshCandidates()
    }

    private func publishCaret() {
        onCaretUTF16Change?(localCaretUTF16)
        onSelectionChange?(localCaretUTF16, localSelectionLength)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundColor = keyboardBackground
        applyDeviceMetrics(keyboardWidth: bounds.width)
        rebuildLayout()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawCandidateBar(context)
        for key in renderedKeys {
            draw(key, context: context)
        }
        if let activeKey, showsPopup(for: activeKey.action) {
            drawPopup(for: activeKey)
        }
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let activeTouch {
            for touch in touches where touch !== activeTouch {
                beginGesture(for: touch)
                updateSecondaryTouch(touch)
            }
            return
        }

        guard let touch = touches.first else { return }
        activeTouch = touch
        beginGesture(for: touch)
        for secondary in touches where secondary !== touch {
            beginGesture(for: secondary)
            updateSecondaryTouch(secondary)
        }

        let hit = keyAt(touch.location(in: self))
        activeAction = hit?.action
        activeKey = hit

        if hit?.action == .delete {
            didRepeatDelete = false
            deleteRepeatCount = 0
            trackpadLastPoint = touch.location(in: self)
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) {
                [weak self] _ in self?.beginDeleteRepeat()
            }
        }
        if hit?.action == .space {
            beginSpaceTrackpadCountdown(from: touch.location(in: self))
        }
        if let hit, showsPopup(for: hit.action) {
            haptic.impactOccurred(intensity: 0.55)
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch !== activeTouch {
            appendSamples(for: touch, phase: .moved, event: event)
            updateSecondaryTouch(touch)
        }
        guard let activeTouch, touches.contains(activeTouch) else { return }
        appendSamples(for: activeTouch, phase: .moved, event: event)

        let point = activeTouch.location(in: self)
        if isSpaceTrackpadActive || (activeAction == .space && !isSpaceTrackpadActive) {
            if !isSpaceTrackpadActive, let start = trackpadLastPoint {
                let travel = hypot(point.x - start.x, point.y - start.y)
                if travel > 6 {
                    activateSpaceTrackpad(at: point)
                }
            }
            if isSpaceTrackpadActive {
                moveCaretWithTrackpad(to: point)
                return
            }
        }

        let hit = keyAt(point)
        guard canSlide(from: activeAction, to: hit?.action), let hit else { return }
        if hit.action != activeAction {
            // Leaving Space cancels the trackpad countdown.
            if activeAction == .space { cancelSpaceTrackpad(commitSpace: false) }
            activeAction = hit.action
            activeKey = hit
            haptic.impactOccurred(intensity: 0.28)
            setNeedsDisplay()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch !== activeTouch {
            let id = ObjectIdentifier(touch)
            let gesture = finishGesture(for: touch, cancelled: false)
            if let action = secondaryTouchActions.removeValue(forKey: id) {
                UIDevice.current.playInputClick()
                perform(action, gesture: gesture, touch: touch)
            }
        }

        guard let activeTouch, touches.contains(activeTouch) else { return }
        deleteTimer?.invalidate()
        deleteTimer = nil
        deleteRepeatCount = 0

        let usedTrackpad = isSpaceTrackpadActive
        let gesture = finishGesture(for: activeTouch, cancelled: false)
        let action = activeAction
        let touch = activeTouch
        cancelSpaceTrackpad(commitSpace: false)
        clearPrimaryTouch()

        if usedTrackpad {
            // Trackpad consumed the Space press — do not insert a space.
            setNeedsDisplay()
            return
        }

        if !(action == .delete && didRepeatDelete), let action {
            UIDevice.current.playInputClick()
            perform(action, gesture: gesture, touch: touch)
        }
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch !== activeTouch {
            _ = finishGesture(for: touch, cancelled: true)
            secondaryTouchActions.removeValue(forKey: ObjectIdentifier(touch))
        }
        guard let activeTouch, touches.contains(activeTouch) else { return }
        deleteTimer?.invalidate()
        deleteTimer = nil
        deleteRepeatCount = 0
        _ = finishGesture(for: activeTouch, cancelled: true)
        cancelSpaceTrackpad(commitSpace: false)
        clearPrimaryTouch()
        setNeedsDisplay()
    }

    private func updateSecondaryTouch(_ touch: UITouch) {
        let hit = keyAt(touch.location(in: self))
        let id = ObjectIdentifier(touch)
        guard let action = hit?.action else {
            secondaryTouchActions.removeValue(forKey: id)
            return
        }
        switch action {
        case .text, .space, .delete, .returnKey, .candidate:
            secondaryTouchActions[id] = action
        default:
            secondaryTouchActions.removeValue(forKey: id)
        }
    }

    private func canSlide(
        from oldAction: InAppKeyboardAction?,
        to newAction: InAppKeyboardAction?
    ) -> Bool {
        isCharacter(oldAction) && isCharacter(newAction)
    }

    private func clearPrimaryTouch() {
        activeTouch = nil
        activeAction = nil
        activeKey = nil
    }

    private func beginDeleteRepeat() {
        didRepeatDelete = true
        repeatDelete()
    }

    private func repeatDelete() {
        guard activeAction == .delete, activeTouch != nil else { return }
        didRepeatDelete = true
        deleteRepeatCount += 1
        let gesture = currentGesture(for: activeTouch)
        if deleteRepeatCount >= 10, deleteRepeatCount.isMultiple(of: 3),
           let deletedWord = deleteWordBeforeCaret() {
            let frame = selectedFrame(for: .delete)
            let tapInfo = makeTapInfo(gesture: gesture, action: .delete, frame: frame)
            emit([
                InAppKeyboardEdit(
                    kind: .delete,
                    originalText: deletedWord,
                    emittedText: "",
                    source: .key,
                    gesture: gesture,
                    selectedKeyFrame: frame,
                    tapInfo: tapInfo,
                    suggestionsOffered: candidateFrames.map(\.text),
                    selectedSuggestion: nil
                )
            ])
            refreshCandidates()
        } else {
            perform(.delete, gesture: gesture, touch: activeTouch)
        }
        haptic.impactOccurred(intensity: 0.22)
        let interval: TimeInterval = deleteRepeatCount < 8 ? 0.085 : 0.06
        deleteTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in self?.repeatDelete()
        }
    }

    // MARK: - Editing and language model

    private func perform(
        _ action: InAppKeyboardAction,
        gesture: TouchGesture?,
        touch _: UITouch?
    ) {
        let key = activeKey ?? key(for: action) ?? hitKey(for: action, gesture: gesture)
        let frame = key?.frame ?? selectedFrame(for: action)
        let tapInfo = makeTapInfo(gesture: gesture, action: action, frame: frame)
        let offered = candidateFrames.map(\.text)

        switch action {
        case .text(let rawText):
            let text = shifted(rawText)
            let replaced = insertText(text)
            emit([
                InAppKeyboardEdit(
                    kind: replaced == nil ? .insert : .replace,
                    originalText: replaced ?? "",
                    emittedText: text,
                    source: .key,
                    gesture: gesture,
                    selectedKeyFrame: frame,
                    tapInfo: tapInfo,
                    suggestionsOffered: offered,
                    selectedSuggestion: nil
                )
            ])
            if shiftState == .uppercase { shiftState = .lowercase }
            refreshCandidates()

        case .delete:
            guard let deleted = deleteBeforeCaret() else { return }
            emit([
                InAppKeyboardEdit(
                    kind: .delete,
                    originalText: deleted,
                    emittedText: "",
                    source: .key,
                    gesture: gesture,
                    selectedKeyFrame: frame,
                    tapInfo: tapInfo,
                    suggestionsOffered: offered,
                    selectedSuggestion: nil
                )
            ])
            refreshCandidates()

        case .space:
            if localSelectionLength > 0 {
                let replaced = insertText(" ")
                emit([
                    InAppKeyboardEdit(
                        kind: replaced == nil ? .insert : .replace,
                        originalText: replaced ?? "",
                        emittedText: " ",
                        source: .key,
                        gesture: gesture,
                        selectedKeyFrame: frame,
                        tapInfo: tapInfo,
                        suggestionsOffered: offered,
                        selectedSuggestion: nil
                    )
                ])
                if layoutMode == .numbers || layoutMode == .symbols {
                    layoutMode = .letters
                }
                shiftState = .lowercase
                refreshCandidates()
                return
            }
            var edits: [InAppKeyboardEdit] = []
            if applyDoubleSpacePeriodIfNeeded(gesture: gesture, frame: frame, tapInfo: tapInfo, offered: offered, into: &edits) {
                emit(edits)
                shiftState = .lowercase
                refreshCandidates()
                return
            }
            // iOS: never autocomplete on space. Only apply the already-emphasized
            // spelling correction (if any). Completions require an explicit tap.
            if let word = currentWord,
               let correction = pendingAutocorrect,
               correction.text.caseInsensitiveCompare(word) != .orderedSame {
                replaceCurrentWord(with: correction.text)
                edits.append(
                    InAppKeyboardEdit(
                        kind: .replace,
                        originalText: word,
                        emittedText: correction.text,
                        source: .autocorrection,
                        gesture: gesture,
                        selectedKeyFrame: frame,
                        tapInfo: tapInfo,
                        suggestionsOffered: offered,
                        selectedSuggestion: correction.text
                    )
                )
            }
            insertText(" ")
            edits.append(
                InAppKeyboardEdit(
                    kind: .insert,
                    originalText: "",
                    emittedText: " ",
                    source: .key,
                    gesture: gesture,
                    selectedKeyFrame: frame,
                    tapInfo: tapInfo,
                    suggestionsOffered: offered,
                    selectedSuggestion: nil
                )
            )
            emit(edits)
            // iOS: after Space on 123 / #+=, return to the letter keyboard.
            if layoutMode == .numbers || layoutMode == .symbols {
                layoutMode = .letters
            }
            shiftState = .lowercase
            refreshCandidates()

        case .returnKey:
            if localSelectionLength > 0 {
                let replaced = insertText("\n")
                emit([
                    InAppKeyboardEdit(
                        kind: replaced == nil ? .insert : .replace,
                        originalText: replaced ?? "",
                        emittedText: "\n",
                        source: .key,
                        gesture: gesture,
                        selectedKeyFrame: frame,
                        tapInfo: tapInfo,
                        suggestionsOffered: offered,
                        selectedSuggestion: nil
                    )
                ])
                if layoutMode == .numbers || layoutMode == .symbols {
                    layoutMode = .letters
                }
                shiftState = .uppercase
                refreshCandidates()
                return
            }
            var edits: [InAppKeyboardEdit] = []
            // Return also commits a pending spelling autocorrect, like iOS.
            if let word = currentWord,
               let correction = pendingAutocorrect,
               correction.text.caseInsensitiveCompare(word) != .orderedSame {
                replaceCurrentWord(with: correction.text)
                edits.append(
                    InAppKeyboardEdit(
                        kind: .replace,
                        originalText: word,
                        emittedText: correction.text,
                        source: .autocorrection,
                        gesture: gesture,
                        selectedKeyFrame: frame,
                        tapInfo: tapInfo,
                        suggestionsOffered: offered,
                        selectedSuggestion: correction.text
                    )
                )
            }
            insertText("\n")
            edits.append(
                InAppKeyboardEdit(
                    kind: .insert,
                    originalText: "",
                    emittedText: "\n",
                    source: .key,
                    gesture: gesture,
                    selectedKeyFrame: frame,
                    tapInfo: tapInfo,
                    suggestionsOffered: offered,
                    selectedSuggestion: nil
                )
            )
            emit(edits)
            if layoutMode == .numbers || layoutMode == .symbols {
                layoutMode = .letters
            }
            shiftState = .uppercase
            refreshCandidates()

        case .candidate(let candidate):
            // Explicit tap only. Completions and corrections never auto-fire.
            if localSelectionLength > 0 {
                let display = unquotedCandidate(candidate)
                let replaced = insertText(display)
                var edits: [InAppKeyboardEdit] = [
                    InAppKeyboardEdit(
                        kind: replaced == nil ? .insert : .replace,
                        originalText: replaced ?? "",
                        emittedText: display,
                        source: .candidate,
                        gesture: gesture,
                        selectedKeyFrame: frame,
                        tapInfo: tapInfo,
                        suggestionsOffered: offered,
                        selectedSuggestion: display
                    )
                ]
                insertText(" ")
                edits.append(
                    InAppKeyboardEdit(
                        kind: .insert,
                        originalText: "",
                        emittedText: " ",
                        source: .candidate,
                        gesture: gesture,
                        selectedKeyFrame: frame,
                        tapInfo: tapInfo,
                        suggestionsOffered: offered,
                        selectedSuggestion: display
                    )
                )
                emit(edits)
                if layoutMode == .numbers || layoutMode == .symbols {
                    layoutMode = .letters
                }
                shiftState = .lowercase
                refreshCandidates()
                return
            }
            let original = currentWord ?? ""
            let display = unquotedCandidate(candidate)
            // Tapping the quoted literal rejects the pending autocorrect.
            let rejectingAutocorrect = candidate.hasPrefix("“") && candidate.hasSuffix("”")
            var edits: [InAppKeyboardEdit] = []
            if original.isEmpty {
                insertText(display)
                edits.append(
                    InAppKeyboardEdit(
                        kind: .insert,
                        originalText: "",
                        emittedText: display,
                        source: .candidate,
                        gesture: gesture,
                        selectedKeyFrame: frame,
                        tapInfo: tapInfo,
                        suggestionsOffered: offered,
                        selectedSuggestion: display
                    )
                )
            } else if rejectingAutocorrect {
                // Keep typed text; just accept the literal (iOS “typed” chip).
            } else {
                replaceCurrentWord(with: display)
                edits.append(
                    InAppKeyboardEdit(
                        kind: .replace,
                        originalText: original,
                        emittedText: display,
                        source: .candidate,
                        gesture: gesture,
                        selectedKeyFrame: frame,
                        tapInfo: tapInfo,
                        suggestionsOffered: offered,
                        selectedSuggestion: display
                    )
                )
            }
            insertText(" ")
            edits.append(
                InAppKeyboardEdit(
                    kind: .insert,
                    originalText: "",
                    emittedText: " ",
                    source: .candidate,
                    gesture: gesture,
                    selectedKeyFrame: frame,
                    tapInfo: tapInfo,
                    suggestionsOffered: offered,
                    selectedSuggestion: rejectingAutocorrect ? original : display
                )
            )
            emit(edits)
            if layoutMode == .numbers || layoutMode == .symbols {
                layoutMode = .letters
            }
            shiftState = .lowercase
            refreshCandidates()
        case .shift:
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShiftTap < 0.35 {
                shiftState = .capsLock
            } else {
                shiftState = shiftState == .lowercase ? .uppercase : .lowercase
            }
            lastShiftTap = now
            setNeedsDisplay()

        case .layout(let layout):
            layoutMode = layout
            shiftState = .lowercase
            rebuildLayout()
            setNeedsDisplay()
        case .globe, .microphone:
            // Visual parity with stock iOS only — no keyboard switch / dictation.
            haptic.impactOccurred(intensity: 0.25)
        }
    }

    private func emit(_ edits: [InAppKeyboardEdit]) {
        guard !edits.isEmpty else { return }
        onEdits?(edits)
        publishCaret()
    }

    private var textBeforeCaret: String {
        let ns = localText as NSString
        let caret = max(0, min(localCaretUTF16, ns.length))
        return ns.substring(to: caret)
    }

    private var currentWord: String? {
        let prefix = textBeforeCaret
        guard let last = prefix.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).last
        else { return nil }
        let word = String(last)
        return word.isEmpty ? nil : word
    }

    private var previousWord: String? {
        let words = textBeforeCaret.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard words.count > 1 else { return nil }
        return String(words[words.count - 2])
    }

    /// Inserts `text` at the caret, replacing any selected range (Notes-like).
    /// Returns the replaced selection, or `nil` if the caret was collapsed.
    @discardableResult
    private func insertText(_ text: String) -> String? {
        let ns = localText as NSString
        let caret = max(0, min(localCaretUTF16, ns.length))
        let sel = max(0, min(localSelectionLength, ns.length - caret))
        let replaced = sel > 0 ? ns.substring(with: NSRange(location: caret, length: sel)) : nil
        localText = ns.replacingCharacters(in: NSRange(location: caret, length: sel), with: text)
        localCaretUTF16 = caret + (text as NSString).length
        localSelectionLength = 0
        return (replaced?.isEmpty == false) ? replaced : nil
    }

    private func deleteSelectedRange() -> String? {
        let ns = localText as NSString
        let caret = max(0, min(localCaretUTF16, ns.length))
        let sel = max(0, min(localSelectionLength, ns.length - caret))
        guard sel > 0 else { return nil }
        let range = NSRange(location: caret, length: sel)
        let deleted = ns.substring(with: range)
        localText = ns.replacingCharacters(in: range, with: "")
        localCaretUTF16 = caret
        localSelectionLength = 0
        return deleted
    }

    private func deleteBeforeCaret() -> String? {
        if let deleted = deleteSelectedRange() { return deleted }
        let ns = localText as NSString
        let caret = max(0, min(localCaretUTF16, ns.length))
        guard caret > 0 else { return nil }
        let range = ns.rangeOfComposedCharacterSequence(at: caret - 1)
        let deleted = ns.substring(with: range)
        localText = ns.replacingCharacters(in: range, with: "")
        localCaretUTF16 = range.location
        localSelectionLength = 0
        return deleted
    }

    private func replaceCurrentWord(with replacement: String) {
        guard let word = currentWord else {
            insertText(replacement)
            return
        }
        let ns = localText as NSString
        let caret = max(0, min(localCaretUTF16, ns.length))
        let wordLen = (word as NSString).length
        let loc = caret - wordLen
        guard loc >= 0 else {
            insertText(replacement)
            return
        }
        localText = ns.replacingCharacters(
            in: NSRange(location: loc, length: wordLen),
            with: replacement
        )
        localCaretUTF16 = loc + (replacement as NSString).length
        localSelectionLength = 0
    }

    private func applyDoubleSpacePeriodIfNeeded(
        gesture: TouchGesture?,
        frame: CGRect?,
        tapInfo: TapInfo,
        offered: [String],
        into edits: inout [InAppKeyboardEdit]
    ) -> Bool {
        let ns = localText as NSString
        let caret = max(0, min(localCaretUTF16, ns.length))
        guard caret >= 1, ns.character(at: caret - 1) == 32 /* space */ else { return false }
        guard caret >= 2 else { return false }
        let prev = ns.character(at: caret - 2)
        // Don't fire after whitespace/newline punctuation chains.
        guard prev != 10, prev != 32, prev != 9 else { return false }

        localText = ns.replacingCharacters(
            in: NSRange(location: caret - 1, length: 1),
            with: ". "
        )
        localCaretUTF16 = caret + 1
        localSelectionLength = 0
        edits.append(
            InAppKeyboardEdit(
                kind: .replace,
                originalText: " ",
                emittedText: ". ",
                source: .key,
                gesture: gesture,
                selectedKeyFrame: frame,
                tapInfo: tapInfo,
                suggestionsOffered: offered,
                selectedSuggestion: nil
            )
        )
        return true
    }

    private func deleteWordBeforeCaret() -> String? {
        if let deleted = deleteSelectedRange() { return deleted }
        let ns = localText as NSString
        var caret = max(0, min(localCaretUTF16, ns.length))
        guard caret > 0 else { return nil }

        // First delete trailing whitespace.
        while caret > 0 {
            let ch = ns.character(at: caret - 1)
            if ch == 32 || ch == 9 || ch == 10 {
                caret -= 1
            } else {
                break
            }
        }
        var start = caret
        while start > 0 {
            let ch = ns.character(at: start - 1)
            if ch == 32 || ch == 9 || ch == 10 { break }
            start -= 1
        }
        guard start < localCaretUTF16 else { return nil }
        let range = NSRange(location: start, length: localCaretUTF16 - start)
        let deleted = ns.substring(with: range)
        localText = ns.replacingCharacters(in: range, with: "")
        localCaretUTF16 = start
        localSelectionLength = 0
        return deleted
    }

    // MARK: - Space trackpad

    private func beginSpaceTrackpadCountdown(from point: CGPoint) {
        cancelSpaceTrackpad(commitSpace: false)
        trackpadLastPoint = point
        trackpadAccum = .zero
        spaceTrackpadTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) {
            [weak self] _ in
            guard let self, let touch = self.activeTouch else { return }
            self.activateSpaceTrackpad(at: touch.location(in: self))
        }
    }

    private func activateSpaceTrackpad(at point: CGPoint) {
        guard !isSpaceTrackpadActive else { return }
        spaceTrackpadTimer?.invalidate()
        spaceTrackpadTimer = nil
        isSpaceTrackpadActive = true
        trackpadLastPoint = point
        trackpadAccum = .zero
        haptic.impactOccurred(intensity: 0.7)
        setNeedsDisplay()
    }

    private func cancelSpaceTrackpad(commitSpace _: Bool) {
        spaceTrackpadTimer?.invalidate()
        spaceTrackpadTimer = nil
        isSpaceTrackpadActive = false
        trackpadLastPoint = nil
        trackpadAccum = .zero
    }

    private func moveCaretWithTrackpad(to point: CGPoint) {
        guard let last = trackpadLastPoint else {
            trackpadLastPoint = point
            return
        }
        let dx = point.x - last.x
        let dy = point.y - last.y
        trackpadLastPoint = point
        trackpadAccum.x += dx
        trackpadAccum.y += dy

        let stepX: CGFloat = 3.2
        let stepY: CGFloat = 10
        var changed = false

        while trackpadAccum.x <= -stepX {
            trackpadAccum.x += stepX
            if moveCaretByGrapheme(-1) { changed = true }
        }
        while trackpadAccum.x >= stepX {
            trackpadAccum.x -= stepX
            if moveCaretByGrapheme(1) { changed = true }
        }
        while trackpadAccum.y <= -stepY {
            trackpadAccum.y += stepY
            let next = caretOnAdjacentLine(direction: -1)
            if next != localCaretUTF16 {
                localCaretUTF16 = next
                changed = true
            }
        }
        while trackpadAccum.y >= stepY {
            trackpadAccum.y -= stepY
            let next = caretOnAdjacentLine(direction: 1)
            if next != localCaretUTF16 {
                localCaretUTF16 = next
                changed = true
            }
        }

        if changed {
            localSelectionLength = 0
            publishCaret()
            refreshCandidates()
        }
    }

    private func moveCaretByGrapheme(_ direction: Int) -> Bool {
        let ns = localText as NSString
        let caret = max(0, min(localCaretUTF16, ns.length))
        if direction < 0 {
            guard caret > 0 else { return false }
            let range = ns.rangeOfComposedCharacterSequence(at: caret - 1)
            localCaretUTF16 = range.location
            localSelectionLength = 0
            return true
        } else {
            guard caret < ns.length else { return false }
            let range = ns.rangeOfComposedCharacterSequence(at: caret)
            localCaretUTF16 = NSMaxRange(range)
            localSelectionLength = 0
            return true
        }
    }

    /// Move caret to the previous/next line, preserving column when possible.
    private func caretOnAdjacentLine(direction: Int) -> Int {
        let ns = localText as NSString
        let caret = max(0, min(localCaretUTF16, ns.length))
        // Column within the current line.
        var lineStart = caret
        while lineStart > 0 {
            if ns.character(at: lineStart - 1) == 10 /* \n */ { break }
            lineStart -= 1
        }
        let column = caret - lineStart

        if direction < 0 {
            guard lineStart > 0 else { return caret }
            var prevEnd = lineStart - 1
            var prevStart = prevEnd
            while prevStart > 0 {
                if ns.character(at: prevStart - 1) == 10 { break }
                prevStart -= 1
            }
            let prevLen = prevEnd - prevStart
            return prevStart + min(column, prevLen)
        } else {
            var lineEnd = caret
            while lineEnd < ns.length {
                if ns.character(at: lineEnd) == 10 { break }
                lineEnd += 1
            }
            guard lineEnd < ns.length else { return caret }
            let nextStart = lineEnd + 1
            var nextEnd = nextStart
            while nextEnd < ns.length {
                if ns.character(at: nextEnd) == 10 { break }
                nextEnd += 1
            }
            let nextLen = nextEnd - nextStart
            return nextStart + min(column, nextLen)
        }
    }

    private func refreshCandidates() {
        let word = currentWord ?? ""
        candidates = decoder.candidates(for: word, previousWord: previousWord)
        pendingAutocorrect = word.isEmpty
            ? nil
            : CorrectionFeedbackPolicy.automaticCorrection(from: candidates, literal: word)
        rebuildLayout()
        setNeedsDisplay()
    }

    private func shifted(_ text: String) -> String {
        guard layoutMode == .letters, shiftState != .lowercase else { return text }
        return text.uppercased()
    }

    private func unquotedCandidate(_ text: String) -> String {
        guard text.count >= 3,
              text.first == "“",
              text.last == "”" else { return text }
        return String(text.dropFirst().dropLast())
    }

    // MARK: - Gesture samples

    private func beginGesture(for touch: UITouch) {
        let first = sample(touch, phase: .began, selectedKey: keyAt(touch.location(in: self)))
        touchGestures[ObjectIdentifier(touch)] = TouchGesture(
            samples: [first],
            initialTarget: first.target,
            startedAt: first.wallTimestamp
        )
    }

    private func appendSamples(
        for touch: UITouch,
        phase: TouchPhase,
        event: UIEvent? = nil
    ) {
        let id = ObjectIdentifier(touch)
        guard var gesture = touchGestures[id] else { return }
        let observed: [UITouch]
        if phase == .moved {
            observed = event?.coalescedTouches(for: touch) ?? [touch]
        } else {
            observed = [touch]
        }
        for item in observed {
            gesture.samples.append(
                sample(item, phase: phase, selectedKey: keyAt(item.location(in: self)))
            )
        }
        touchGestures[id] = gesture
    }

    private func currentGesture(for touch: UITouch?) -> TouchGesture? {
        guard let touch else { return nil }
        return touchGestures[ObjectIdentifier(touch)]
    }

    private func finishGesture(for touch: UITouch, cancelled: Bool) -> TouchGesture? {
        appendSamples(for: touch, phase: cancelled ? .cancelled : .ended)
        guard var gesture = touchGestures.removeValue(forKey: ObjectIdentifier(touch))
        else { return nil }
        let last = gesture.samples.last
        gesture.finalTarget = last?.target
        if let activeAction {
            gesture.selectedFrame = selectedFrame(for: activeAction).map(CodableRect.init)
                ?? last?.target?.frame
        } else {
            gesture.selectedFrame = last?.target?.frame
        }
        gesture.endedAt = last?.wallTimestamp ?? Date()
        if let first = gesture.samples.first?.monotonicTimestamp,
           let lastTime = last?.monotonicTimestamp {
            gesture.durationMilliseconds = max(0, (lastTime - first) * 1_000)
        }
        gesture.wasCancelled = cancelled
        gesture.didSlide = gesture.initialTarget?.identifier != gesture.finalTarget?.identifier
        return gesture
    }

    private func sample(
        _ touch: UITouch,
        phase: TouchPhase,
        selectedKey: InAppRenderedKey?
    ) -> TouchSample {
        let point = touch.location(in: self)
        let precise = touch.preciseLocation(in: self)
        let target = selectedKey.map {
            TouchTarget(
                identifier: identifier(for: $0.action),
                key: displayLabel(for: $0),
                frame: CodableRect($0.frame)
            )
        }
        let frame = selectedKey?.frame
        let local = frame.map { CGPoint(x: point.x - $0.minX, y: point.y - $0.minY) }
        let normalized = frame.flatMap { rect -> CGPoint? in
            guard rect.width > 0, rect.height > 0 else { return nil }
            return CGPoint(
                x: (point.x - rect.minX) / rect.width,
                y: (point.y - rect.minY) / rect.height
            )
        }
        return TouchSample(
            phase: phase,
            wallTimestamp: Date(
                timeIntervalSinceNow: touch.timestamp - ProcessInfo.processInfo.systemUptime
            ),
            monotonicTimestamp: touch.timestamp,
            absolutePosition: CodablePoint(point),
            preciseAbsolutePosition: CodablePoint(precise),
            localPosition: local.map(CodablePoint.init),
            normalizedPosition: normalized.map(CodablePoint.init),
            radius: Double(touch.majorRadius),
            radiusTolerance: Double(touch.majorRadiusTolerance),
            force: Double(touch.force),
            maximumForce: Double(touch.maximumPossibleForce),
            touchType: touch.type.rawValue,
            target: target
        )
    }

    private func makeTapInfo(
        gesture: TouchGesture?,
        action: InAppKeyboardAction,
        frame: CGRect?
    ) -> TapInfo {
        guard let frame else { return .none }
        let point = gesture?.samples.last?.absolutePosition?.cgPoint
            ?? CGPoint(x: frame.midX, y: frame.midY)
        return TapInfo(
            keyLabel: studyLabel(for: action),
            tapLocalX: Double(point.x - frame.minX),
            tapLocalY: Double(point.y - frame.minY),
            keyWidth: Double(frame.width),
            keyHeight: Double(frame.height)
        )
    }

    // MARK: - Hit testing and layout

    private func keyAt(_ point: CGPoint) -> InAppRenderedKey? {
        if let candidate = candidateFrames.first(where: { $0.frame.contains(point) }) {
            return InAppRenderedKey(
                label: candidate.text,
                action: .candidate(candidate.text),
                frame: candidate.frame,
                isSpecial: false
            )
        }

        // Tight hit boxes — oversized hit areas cause neighbor-key mistakes
        // when geometry already matches iOS.
        if let exact = renderedKeys.first(where: {
            $0.frame.insetBy(dx: -1.5, dy: -2.5).contains(point)
        }) {
            return exact
        }

        let letters = renderedKeys.filter(\.isLetter)
        guard !letters.isEmpty else { return nil }
        let envelope = letters.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            .insetBy(dx: -4, dy: -5)
        guard envelope.contains(point) else { return nil }

        var best: InAppRenderedKey?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for key in letters {
            let dx = max(key.frame.minX - point.x, 0, point.x - key.frame.maxX)
            let dy = max(key.frame.minY - point.y, 0, point.y - key.frame.maxY)
            let distance = hypot(dx, dy)
            let threshold = min(key.frame.width, key.frame.height) * 0.35
            if distance < bestDistance, distance <= threshold {
                bestDistance = distance
                best = key
            }
        }
        return best
    }

    private func rebuildLayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        renderedKeys.removeAll(keepingCapacity: true)
        candidateFrames.removeAll(keepingCapacity: true)

        // Width-driven iOS geometry: letter keys keep a fixed size for this
        // screen width. We do NOT stretch rows to fill leftover height — that
        // mismatch is what made targets feel “off” vs the system keyboard.
        let side = layoutSpec.sideInset
        let gap = layoutSpec.keyGap
        let rowGap = layoutSpec.rowGap
        let rowHeight = layoutSpec.rowHeight
        let top = layoutSpec.candidateBarHeight + layoutSpec.topPad

        let rows: [[(String, InAppKeyboardAction, CGFloat, Bool)]]
        switch layoutMode {
        case .letters, .emoji:
            rows = [
                Array("qwertyuiop").map { (String($0), .text(String($0)), 1, false) },
                Array("asdfghjkl").map { (String($0), .text(String($0)), 1, false) },
                [("shift", .shift, 1.5, true)]
                    + Array("zxcvbnm").map { (String($0), .text(String($0)), 1, false) }
                    + [("delete", .delete, 1.5, true)],
                [
                    ("123", .layout(.numbers), 1.5, true),
                    ("space", .space, 6.0, false),
                    ("return", .returnKey, 1.5, true)
                ]
            ]
        case .numbers:
            rows = [
                Array("1234567890").map { (String($0), .text(String($0)), 1, false) },
                Array("-/:;()$&@\"").map { (String($0), .text(String($0)), 1, false) },
                [("#+=", .layout(.symbols), 1.5, true)]
                    + Array(".,?!'").map { (String($0), .text(String($0)), 1, false) }
                    + [("delete", .delete, 1.5, true)],
                [
                    ("ABC", .layout(.letters), 1.5, true),
                    ("space", .space, 6.0, false),
                    ("return", .returnKey, 1.5, true)
                ]
            ]
        case .symbols:
            rows = [
                Array("[]{}#%^*+=").map { (String($0), .text(String($0)), 1, false) },
                Array("_\\|~<>€£¥•").map { (String($0), .text(String($0)), 1, false) },
                [("123", .layout(.numbers), 1.5, true)]
                    + Array(".,?!'").map { (String($0), .text(String($0)), 1, false) }
                    + [("delete", .delete, 1.5, true)],
                [
                    ("ABC", .layout(.letters), 1.5, true),
                    ("space", .space, 6.0, false),
                    ("return", .returnKey, 1.5, true)
                ]
            ]
        }

        for (rowIndex, row) in rows.enumerated() {
            let totalUnits = row.reduce(CGFloat.zero) { $0 + $1.2 }
            let available = bounds.width - side * 2 - gap * CGFloat(max(0, row.count - 1))
            let unitWidth = available / totalUnits
            let rowWidth = unitWidth * totalUnits + gap * CGFloat(max(0, row.count - 1))
            var x = rowIndex == 1 && layoutMode == .letters
                ? (bounds.width - rowWidth) / 2
                : side
            let y = top + CGFloat(rowIndex) * (rowHeight + rowGap)
            for item in row {
                let width = unitWidth * item.2
                renderedKeys.append(
                    InAppRenderedKey(
                        label: item.0,
                        action: item.1,
                        frame: CGRect(x: x, y: y, width: width, height: rowHeight),
                        isSpecial: item.3
                    )
                )
                x += width + gap
            }
        }

        appendHomeIndicatorIcons()
        rebuildCandidateFrames()
    }

    /// Stock iPhone keyboard puts globe (left) and mic (right) in the
    /// home-indicator strip — icon only, no key chrome.
    private func appendHomeIndicatorIcons() {
        let inset = SystemKeyboardMetrics.bottomSafeAreaInset()
        guard inset > 8, let lastRowMaxY = renderedKeys.map(\.frame.maxY).max() else { return }
        let hit: CGFloat = 44
        let y = lastRowMaxY + max(0, (inset - hit) / 2)
        let height = max(hit, inset - 2)
        renderedKeys.append(
            InAppRenderedKey(
                label: "globe",
                action: .globe,
                frame: CGRect(x: layoutSpec.sideInset, y: y, width: hit, height: height),
                isSpecial: true
            )
        )
        renderedKeys.append(
            InAppRenderedKey(
                label: "mic",
                action: .microphone,
                frame: CGRect(
                    x: bounds.width - layoutSpec.sideInset - hit,
                    y: y,
                    width: hit,
                    height: height
                ),
                isSpecial: true
            )
        )
    }

    /// iOS QuickType layout:
    /// - Spelling correction pending → emphasize `“typed”` | correction | alt
    ///   (text unchanged until Space or a tap)
    /// - Otherwise → up to 3 suggestions/completions (tap to accept only)
    private func rebuildCandidateFrames() {
        candidateFrames.removeAll(keepingCapacity: true)
        let word = currentWord ?? ""
        var items: [String] = []

        if let correction = pendingAutocorrect, !word.isEmpty {
            items = ["“\(word)”", correction.text]
            if let third = candidates.first(where: {
                $0.text.caseInsensitiveCompare(word) != .orderedSame
                    && $0.text.caseInsensitiveCompare(correction.text) != .orderedSame
            }) {
                items.append(third.text)
            }
        } else {
            // Suggestions only — never treat these as pending auto-replace.
            items = candidates.prefix(3).map(\.text)
        }

        guard !items.isEmpty else { return }
        let width = bounds.width / CGFloat(items.count)
        candidateFrames = items.enumerated().map {
            ($0.element, CGRect(
                x: CGFloat($0.offset) * width,
                y: 0,
                width: width,
                height: candidateHeight
            ))
        }
    }

    private func key(for action: InAppKeyboardAction) -> InAppRenderedKey? {
        renderedKeys.first { $0.action == action }
    }

    private func hitKey(for action: InAppKeyboardAction, gesture: TouchGesture?) -> InAppRenderedKey? {
        if case .candidate(let text) = action,
           let frame = candidateFrames.first(where: { $0.text == text })?.frame {
            return InAppRenderedKey(label: text, action: action, frame: frame, isSpecial: false)
        }
        return key(for: action)
    }

    private func selectedFrame(for action: InAppKeyboardAction) -> CGRect? {
        if case .candidate(let candidate) = action {
            return candidateFrames.first { $0.text == candidate }?.frame
        }
        return key(for: action)?.frame
    }

    private func isCharacter(_ action: InAppKeyboardAction?) -> Bool {
        if case .text = action { return true }
        return false
    }

    private func showsPopup(for action: InAppKeyboardAction) -> Bool {
        if case .text(let text) = action { return text.count == 1 }
        return false
    }

    private func identifier(for action: InAppKeyboardAction) -> String {
        switch action {
        case .text(let text): return "key:\(text)"
        case .shift: return "key:shift"
        case .delete: return "key:delete"
        case .space: return "key:space"
        case .returnKey: return "key:return"
        case .globe: return "key:globe"
        case .microphone: return "key:mic"
        case .layout(let layout): return "layout:\(layout.rawValue)"
        case .candidate(let text): return "candidate:\(text)"
        }
    }

    private func studyLabel(for action: InAppKeyboardAction) -> String {
        switch action {
        case .text(let text): return shifted(text)
        case .delete: return "delete"
        case .space: return "space"
        case .returnKey: return "return"
        case .globe: return "globe"
        case .microphone: return "mic"
        case .candidate(let text): return unquotedCandidate(text)
        case .shift: return "shift"
        case .layout(let layout): return layout.rawValue
        }
    }

    // MARK: - Drawing

    private var keyboardBackground: UIColor {
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 0.176, green: 0.176, blue: 0.184, alpha: 1)
            : UIColor(red: 0.82, green: 0.835, blue: 0.86, alpha: 1)
    }

    private var letterFill: UIColor {
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 0.34, green: 0.34, blue: 0.35, alpha: 1)
            : .white
    }

    private var specialFill: UIColor {
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 0.27, green: 0.27, blue: 0.28, alpha: 1)
            : UIColor(red: 0.69, green: 0.71, blue: 0.73, alpha: 1)
    }

    private func drawCandidateBar(_ context: CGContext) {
        keyboardBackground.setFill()
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: candidateHeight))

        for (index, item) in candidateFrames.enumerated() {
            let isAutocorrectCenter = pendingAutocorrect != nil && index == 1
            let isSelected = activeAction == .candidate(item.text)

            // iOS QuickType: pending spelling fix is a rounded gray emphasized chip.
            if isAutocorrectCenter {
                let pill = item.frame.insetBy(dx: 5, dy: 6)
                let pillFill: UIColor = traitCollection.userInterfaceStyle == .dark
                    ? UIColor(white: 0.38, alpha: 1)
                    : UIColor(white: 0.78, alpha: 1)
                pillFill.setFill()
                UIBezierPath(roundedRect: pill, cornerRadius: 8).fill()
            } else if index > 0 {
                UIColor.separator.setStroke()
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: item.frame.minX, y: 10))
                context.addLine(to: CGPoint(x: item.frame.minX, y: candidateHeight - 10))
                context.strokePath()
            }

            if isSelected && !isAutocorrectCenter {
                UIColor.label.withAlphaComponent(0.1).setFill()
                UIBezierPath(
                    roundedRect: item.frame.insetBy(dx: 2, dy: 4),
                    cornerRadius: 6
                ).fill()
            }

            let font: UIFont = isAutocorrectCenter
                ? .systemFont(ofSize: 17, weight: .semibold)
                : .systemFont(ofSize: 17, weight: .regular)
            drawText(item.text, in: item.frame, font: font)
        }
    }

    private func draw(_ key: InAppRenderedKey, context: CGContext) {
        let isHomeIcon = key.action == .globe || key.action == .microphone
        if !isHomeIcon {
            let engagedShift = key.action == .shift && shiftState != .lowercase
            let base = (key.isSpecial && !engagedShift) || key.action == .space
                ? specialFill
                : letterFill
            var fill = activeAction == key.action ? base.withAlphaComponent(0.58) : base
            // Dim keys while Space trackpad is steering the caret (iOS-like).
            if isSpaceTrackpadActive, key.action != .space {
                fill = fill.withAlphaComponent(0.35)
            } else if isSpaceTrackpadActive, key.action == .space {
                fill = letterFill
            }
            fill.setFill()
            let path = UIBezierPath(roundedRect: key.frame, cornerRadius: 5.5)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 1), blur: 0, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            path.fill()
            context.restoreGState()
            if traitCollection.userInterfaceStyle != .dark {
                UIColor.black.withAlphaComponent(0.16).setStroke()
                path.lineWidth = 0.4
                path.stroke()
            }
        }

        if let symbol = symbol(for: key.action) {
            let pointSize: CGFloat
            let weight: UIImage.SymbolWeight
            if isHomeIcon {
                pointSize = isLandscape ? 18 : 21
                weight = key.action == .globe ? .ultraLight : .regular
            } else {
                pointSize = isLandscape ? 17 : 18.5
                weight = .regular
            }
            let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            let tint: UIColor = isHomeIcon
                ? (activeAction == key.action ? .label : UIColor.label.withAlphaComponent(0.92))
                : .label
            if let image = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(tint, renderingMode: .alwaysOriginal) {
                image.draw(at: CGPoint(
                    x: key.frame.midX - image.size.width / 2,
                    y: key.frame.midY - image.size.height / 2
                ))
            }
        } else if key.action == .space {
            let en = "EN"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: isLandscape ? 9 : 10, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let size = en.size(withAttributes: attrs)
            en.draw(
                at: CGPoint(
                    x: key.frame.maxX - size.width - 8,
                    y: key.frame.maxY - size.height - 5
                ),
                withAttributes: attrs
            )
        } else {
            let label = displayLabel(for: key)
            let size: CGFloat
            if isCharacter(key.action) {
                size = letterFontSize
            } else {
                size = isLandscape ? 13.5 : 15
            }
            drawText(label, in: key.frame, font: .systemFont(ofSize: size, weight: .regular))
        }
    }

    private func drawPopup(for key: InAppRenderedKey) {
        let frame = key.frame
        let width = max(46, frame.width + 14)
        let height: CGFloat = isLandscape ? 44 : 56
        let x = min(max(2, frame.midX - width / 2), bounds.width - width - 2)
        let popup = CGRect(
            x: x,
            y: max(candidateHeight + 2, frame.minY - height - 6),
            width: width,
            height: height
        )
        let bubble = UIBezierPath(roundedRect: popup, cornerRadius: 10)
        let stem = UIBezierPath(
            roundedRect: CGRect(
                x: frame.midX - min(28, frame.width) / 2,
                y: popup.maxY - 8,
                width: min(28, frame.width),
                height: max(10, frame.minY - popup.maxY + 10)
            ),
            cornerRadius: 5
        )
        bubble.append(stem)
        letterFill.setFill()
        bubble.fill()
        drawText(
            displayLabel(for: key),
            in: popup,
            font: .systemFont(ofSize: isLandscape ? 22 : 28)
        )
    }

    private func symbol(for action: InAppKeyboardAction) -> String? {
        switch action {
        case .delete: return "delete.left"
        case .shift:
            switch shiftState {
            case .lowercase: return "shift"
            case .uppercase: return "shift.fill"
            case .capsLock: return "capslock.fill"
            }
        case .globe:
            return "globe"
        case .microphone:
            return "mic"
        default: return nil
        }
    }

    private func displayLabel(for key: InAppRenderedKey) -> String {
        guard isCharacter(key.action), layoutMode == .letters else { return key.label }
        return shiftState == .lowercase ? key.label : key.label.uppercased()
    }

    private func drawText(_ text: String, in rect: CGRect, font: UIFont) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

}

extension InAppResearchKeyboard: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

private extension CGFloat {
    var nonZero: CGFloat? { self > 0.5 ? self : nil }
}
