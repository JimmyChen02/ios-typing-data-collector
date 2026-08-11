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
            // Assigning text moves the caret; flag it so the resulting
            // selection change isn't logged as the participant repositioning.
            context.coordinator.pendingProgrammatic = true
            uiView.text = text
        }
        uiView.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        /// Set by shouldChangeTextIn and consumed by the next selection
        /// change, which distinguishes the caret merely advancing as you type
        /// from a deliberate reposition.
        private var pendingAfterTextChange = false

        /// Set by updateUIView while it assigns `text` wholesale. Consumed by
        /// the next selection change, since UIKit may deliver that callback
        /// asynchronously.
        var pendingProgrammatic = false

        private var prevSelStart = 0
        private var prevSelLength = 0

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
            // Previously computed only inside the .replace branch below and
            // then discarded; the log needs it for every event so deletes
            // record which character went away and a replay is checkable.
            let replacedText = currentText.substring(with: range)
            let resultingLength = currentText.replacingCharacters(in: range, with: replacementText).count

            KeystrokeLogger.shared.logEvent(
                type: eventType,
                replacedText: replacedText,
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
                // punctuation): show it as one [old→new] token.
                RecentKeysTracker.shared.recordReplacement(
                    old: replacedText,
                    new: replacementText
                )
            case .insert, .paste:
                RecentKeysTracker.shared.record(replacementText)
            }

            // Consumed by the textViewDidChangeSelection that UIKit delivers
            // once this edit is applied.
            pendingAfterTextChange = true

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

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            let afterTextChange = pendingAfterTextChange
            let programmatic = pendingProgrammatic
            pendingAfterTextChange = false
            pendingProgrammatic = false

            var caretX: Double?
            var caretY: Double?
            var caretH: Double?
            if let selection = textView.selectedTextRange {
                let rect = textView.caretRect(for: selection.start)
                // caretRect can return a null/infinite rect while the layout
                // is in flux; an empty column beats a garbage coordinate.
                if rect.origin.x.isFinite, rect.origin.y.isFinite, rect.height.isFinite {
                    caretX = Double(rect.origin.x)
                    caretY = Double(rect.origin.y)
                    caretH = Double(rect.height)
                }
            }

            var touchX: Double?
            var touchY: Double?
            var touchPhase: String?
            var touchAgeMs: Double?
            if let touch = LastTouchTracker.shared.latest, let window = textView.window {
                let local = textView.convert(touch.point, from: window)
                touchX = Double(local.x)
                touchY = Double(local.y)
                touchPhase = touch.phase
                touchAgeMs = Date().timeIntervalSince(touch.date) * 1000.0
            }

            CursorLogger.shared.log(CursorSample(
                selStart: range.location,
                selLength: range.length,
                prevSelStart: prevSelStart,
                prevSelLength: prevSelLength,
                caretX: caretX, caretY: caretY, caretH: caretH,
                touchX: touchX, touchY: touchY,
                touchPhase: touchPhase, touchAgeMs: touchAgeMs,
                afterTextChange: afterTextChange,
                programmatic: programmatic,
                // NSString length, not String.count: selectedRange is a
                // UTF-16 offset, so the length must be in the same units for
                // the two to be comparable.
                textLength: (textView.text as NSString).length
            ))

            prevSelStart = range.location
            prevSelLength = range.length
        }
    }
}
