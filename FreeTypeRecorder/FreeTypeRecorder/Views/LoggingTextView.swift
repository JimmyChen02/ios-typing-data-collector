import SwiftUI
import UIKit

/// A UITextView wrapper that logs every keystroke event to KeystrokeLogger
/// while behaving like a normal multi-line text editor — the
/// FreeTypeRecorder analogue of TypingResearch's LoggingTextField (which
/// wraps UITextField; this app's notepad needs multi-line input, hence
/// UITextView).
struct LoggingTextView: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        // Deliberately the opposite of TypingResearch's LoggingTextField
        // (which disables these to get clean word-accuracy measurements
        // against a target word). This app is free typing with no target
        // word to score against, so the point is capturing genuinely
        // authentic system-keyboard behavior — autocorrect, the QuickType
        // predictive bar, smart punctuation, all on, same as any other app.
        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.spellCheckingType = .yes
        textView.smartQuotesType = .yes
        textView.smartDashesType = .yes
        textView.smartInsertDeleteType = .yes
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText: String) -> Bool {
            let eventType: KeystrokeEventType
            if replacementText.isEmpty && range.length > 0 {
                eventType = .delete
            } else if replacementText.count == 1 && range.length == 0 {
                eventType = .insert
            } else if range.length > 0 {
                eventType = .replace
            } else {
                eventType = .paste
            }

            let currentText = (textView.text as NSString)
            let resultingLength = currentText.replacingCharacters(in: range, with: replacementText).count

            KeystrokeLogger.shared.logEvent(
                type: eventType,
                replacementText: replacementText,
                rangeStart: range.location,
                rangeLength: range.length,
                resultingTextLength: resultingLength
            )
            switch eventType {
            case .delete:
                RecentKeysTracker.shared.record("⌫")
            case .replace:
                // A keyboard substitution (autocorrect, QuickType pick, smart
                // punctuation): show it as one [old→new] token. `currentText`
                // still holds the pre-edit text here, so `range` is the old.
                RecentKeysTracker.shared.recordReplacement(
                    old: currentText.substring(with: range),
                    new: replacementText
                )
            case .insert, .paste:
                RecentKeysTracker.shared.record(replacementText)
            }

            // Let UIKit apply the edit itself — this is purely an observer.
            // Returning false and reassigning `text` ourselves would replace
            // uiView.text wholesale on every keystroke via updateUIView,
            // which resets the cursor to the end each time (the bug: fixing
            // a typo mid-text kept bouncing the cursor back to the end).
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
