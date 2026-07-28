import SwiftUI
import UIKit

/// Text field that mirrors iOS QuickType visuals using the keyboard extension's
/// live prediction state: gray inline suffix at the caret, and a temporary
/// gray underline on an autocorrected word.
struct PredictionAwareTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> PredictionTextView {
        let view = PredictionTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 8
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.keyboardDismissMode = .interactive
        context.coordinator.observePredictionUpdates(on: view)
        return view
    }

    func updateUIView(_ uiView: PredictionTextView, context: Context) {
        if uiView.text != text {
            let selected = uiView.selectedRange
            uiView.text = text
            let clamped = NSRange(
                location: min(selected.location, (text as NSString).length),
                length: 0
            )
            uiView.selectedRange = clamped
        }
        uiView.applyLivePrediction(SharedKeyboardPreferences.shared.livePrediction)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        private var timer: Timer?

        init(text: Binding<String>) {
            _text = text
        }

        deinit {
            timer?.invalidate()
        }

        func observePredictionUpdates(on view: PredictionTextView) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak view] _ in
                view?.applyLivePrediction(SharedKeyboardPreferences.shared.livePrediction)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text ?? ""
            if let predictionView = textView as? PredictionTextView {
                predictionView.applyLivePrediction(SharedKeyboardPreferences.shared.livePrediction)
            }
        }
    }
}

final class PredictionTextView: UITextView {
    private let ghostLabel = UILabel()
    private var underlinedRange: NSRange?
    private var correctionOriginal: String?
    private var lastAppliedState = KeyboardLivePredictionState.empty

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        ghostLabel.font = .preferredFont(forTextStyle: .body)
        ghostLabel.textColor = .placeholderText
        ghostLabel.numberOfLines = 1
        ghostLabel.isUserInteractionEnabled = false
        addSubview(ghostLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyLivePrediction(_ state: KeyboardLivePredictionState) {
        guard state != lastAppliedState || ghostLabel.text != state.inlineSuffix else {
            // Still refresh underline expiry.
            if !state.hasActiveCorrection, underlinedRange != nil {
                clearUnderline()
            }
            return
        }
        lastAppliedState = state

        // Gray inline prediction sits after the caret — visual only, not in the document.
        if state.hasInlinePrediction,
           let selected = selectedTextRange,
           selectedTextRange?.start == selected.end {
            let caret = caretRect(for: selected.start)
            ghostLabel.text = state.inlineSuffix
            ghostLabel.font = font
            ghostLabel.sizeToFit()
            ghostLabel.frame.origin = CGPoint(
                x: caret.maxX + 1,
                y: caret.midY - ghostLabel.bounds.height / 2
            )
            ghostLabel.isHidden = false
        } else {
            ghostLabel.text = nil
            ghostLabel.isHidden = true
        }

        if state.hasActiveCorrection,
           let replacement = state.correctionReplacement {
            applyUnderline(for: replacement, original: state.correctionOriginal)
        } else {
            clearUnderline()
        }
        setNeedsDisplay()
    }

    private func applyUnderline(for replacement: String, original: String?) {
        let nsText = text as NSString
        let search = nsText.range(of: replacement, options: .backwards)
        guard search.location != NSNotFound else {
            clearUnderline()
            return
        }
        underlinedRange = search
        correctionOriginal = original

        let attributed = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes(
            [
                .font: font as Any,
                .foregroundColor: textColor ?? UIColor.label
            ],
            range: full
        )
        attributed.addAttributes(
            [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: UIColor.secondaryLabel
            ],
            range: search
        )
        // Keep selection while swapping attributed text.
        let selected = selectedRange
        attributedText = attributed
        selectedRange = selected
    }

    private func clearUnderline() {
        guard underlinedRange != nil || correctionOriginal != nil else { return }
        underlinedRange = nil
        correctionOriginal = nil
        let selected = selectedRange
        let plain = text ?? ""
        attributedText = NSAttributedString(
            string: plain,
            attributes: [
                .font: font as Any,
                .foregroundColor: textColor ?? UIColor.label
            ]
        )
        selectedRange = selected
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let range = underlinedRange,
              let original = correctionOriginal,
              let replacement = lastAppliedState.correctionReplacement
        else { return }

        let point = recognizer.location(in: self)
        if let pos = closestPosition(to: point),
           let start = position(from: beginningOfDocument, offset: range.location),
           let end = position(from: beginningOfDocument, offset: NSMaxRange(range)),
           let textRange = textRange(from: start, to: end) {
            let rects = selectionRects(for: textRange)
            let hit = rects.contains { $0.rect.contains(point) }
            guard hit else { return }

            // Revert the autocorrected word when the underlined chip is tapped.
            let ns = text as NSString
            text = ns.replacingCharacters(in: range, with: original)
            delegate?.textViewDidChange?(self)
            clearUnderline()
            var cleared = SharedKeyboardPreferences.shared.livePrediction
            cleared.correctionOriginal = nil
            cleared.correctionReplacement = nil
            cleared.correctionExpires = nil
            SharedKeyboardPreferences.shared.livePrediction = cleared
            _ = replacement
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Reposition ghost after rotation / size changes.
        applyLivePrediction(SharedKeyboardPreferences.shared.livePrediction)
    }
}
