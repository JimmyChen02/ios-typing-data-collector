import SwiftUI
import UIKit

/// A completed autocorrection that iOS temporarily underlines in grey so the
/// user can tap it and restore the original typed text.
struct RevertibleAutocorrection: Equatable {
    var original: String
    var replacement: String
    /// UTF-16 location of `replacement` in the full text.
    var utf16Location: Int
}

/// Editable text surface with a native blinking caret (system keyboard suppressed).
/// - Red dotted underlines on misspelled completed words (`UITextChecker`)
/// - Temporary grey underline on the latest LM autocorrection (tap to revert)
/// - Tap elsewhere to place the caret
struct AnnotatedTypingCanvas: UIViewRepresentable {
    @Binding var text: String
    @Binding var caretUTF16: Int
    var revertible: RevertibleAutocorrection?
    var placeholder: String = "Start typing…"
    var onRevertAutocorrection: (RevertibleAutocorrection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> CursorTextView {
        let view = CursorTextView()
        view.isEditable = true
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.textContainer.lineFragmentPadding = 0
        view.tintColor = UIColor(red: 0.89, green: 0.52, blue: 0.22, alpha: 1)
        view.linkTextAttributes = [
            .foregroundColor: UIColor.label,
            .underlineColor: UIColor.systemGray,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        // Keep first-responder so the caret blinks; suppress the system keyboard.
        view.inputView = UIView(frame: .zero)
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        view.delegate = context.coordinator
        view.placeholderLabel.text = placeholder
        context.coordinator.apply(to: view, forceCaret: true)
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ view: CursorTextView, context: Context) {
        context.coordinator.parent = self
        view.placeholderLabel.text = placeholder
        context.coordinator.apply(to: view, forceCaret: false)
        if !view.isFirstResponder {
            _ = view.becomeFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AnnotatedTypingCanvas
        private let checker = UITextChecker()
        private var isApplying = false

        init(_ parent: AnnotatedTypingCanvas) {
            self.parent = parent
        }

        func apply(to view: CursorTextView, forceCaret: Bool) {
            isApplying = true
            defer { isApplying = false }

            let font = UIFont.systemFont(ofSize: 22, weight: .regular)
            let caret = max(0, min(parent.caretUTF16, (parent.text as NSString).length))
            view.typingAttributes = [
                .font: font,
                .foregroundColor: UIColor.label
            ]

            if parent.text.isEmpty {
                if !view.text.isEmpty {
                    view.attributedText = NSAttributedString(string: "")
                }
                view.font = font
                view.selectedRange = NSRange(location: 0, length: 0)
                view.placeholderLabel.isHidden = false
                return
            }

            view.placeholderLabel.isHidden = true
            let nsText = parent.text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            let attributed = NSMutableAttributedString(
                string: parent.text,
                attributes: [
                    .font: font,
                    .foregroundColor: UIColor.label
                ]
            )

            let incompleteTrailing = incompleteWordRangeBeforeCaret(
                in: parent.text,
                caretUTF16: caret
            )
            var searchLocation = 0
            while searchLocation < fullRange.length {
                let misspelled = checker.rangeOfMisspelledWord(
                    in: parent.text,
                    range: fullRange,
                    startingAt: searchLocation,
                    wrap: false,
                    language: preferredLanguage
                )
                if misspelled.location == NSNotFound { break }

                let overlapsIncomplete = incompleteTrailing.map {
                    NSIntersectionRange(misspelled, $0).length > 0
                } ?? false
                let overlapsRevertible = parent.revertible.map {
                    let r = NSRange(location: $0.utf16Location, length: ($0.replacement as NSString).length)
                    return NSIntersectionRange(misspelled, r).length > 0
                } ?? false

                if !overlapsIncomplete && !overlapsRevertible {
                    attributed.addAttributes(
                        [
                            .underlineStyle: NSUnderlineStyle.single.rawValue
                                | NSUnderlineStyle.patternDot.rawValue,
                            .underlineColor: UIColor.systemRed
                        ],
                        range: misspelled
                    )
                }
                searchLocation = misspelled.location + max(1, misspelled.length)
            }

            if let mark = parent.revertible {
                let range = NSRange(
                    location: mark.utf16Location,
                    length: (mark.replacement as NSString).length
                )
                if range.location >= 0,
                   NSMaxRange(range) <= attributed.length,
                   nsText.substring(with: range) == mark.replacement {
                    attributed.addAttributes(
                        [
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .underlineColor: UIColor.systemGray,
                            .link: URL(string: "revert://autocorrection") as Any
                        ],
                        range: range
                    )
                }
            }

            let offset = view.contentOffset
            let textChanged = view.text != parent.text
            if textChanged {
                view.attributedText = attributed
            } else {
                view.textStorage.setAttributedString(attributed)
            }
            let clamped = max(0, min(caret, attributed.length))
            if forceCaret || textChanged || (view.selectedRange.length == 0 && view.selectedRange.location != clamped) {
                view.selectedRange = NSRange(location: clamped, length: 0)
            }
            view.setContentOffset(offset, animated: false)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplying else { return }
            let maxLen = (parent.text as NSString).length
            let clamped = max(0, min(textView.selectedRange.location, maxLen))
            if parent.caretUTF16 != clamped {
                parent.caretUTF16 = clamped
            }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            // All typing comes from the in-app research keyboard.
            false
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            guard URL.scheme == "revert", let mark = parent.revertible else { return false }
            let range = NSRange(
                location: mark.utf16Location,
                length: (mark.replacement as NSString).length
            )
            if NSIntersectionRange(characterRange, range).length > 0 {
                parent.onRevertAutocorrection(mark)
            }
            return false
        }

        private var preferredLanguage: String {
            let languages = UITextChecker.availableLanguages
            if languages.contains("en_US") { return "en_US" }
            return languages.first ?? "en"
        }

        private func incompleteWordRangeBeforeCaret(in text: String, caretUTF16: Int) -> NSRange? {
            let ns = text as NSString
            let caret = max(0, min(caretUTF16, ns.length))
            guard caret > 0 else { return nil }
            let ch = ns.character(at: caret - 1)
            if let scalar = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return nil
            }
            var start = caret
            while start > 0 {
                let unit = ns.character(at: start - 1)
                if let scalar = UnicodeScalar(unit),
                   CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    break
                }
                start -= 1
            }
            guard start < caret else { return nil }
            return NSRange(location: start, length: caret - start)
        }
    }
}

final class CursorTextView: UITextView {
    let placeholderLabel = UILabel()

    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.font = .systemFont(ofSize: 22, weight: .regular)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16)
        ])

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}
