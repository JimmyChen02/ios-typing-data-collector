import SwiftUI
import UIKit

// Free Writing Mode's UITextView wrapper. Mirrors LoggingTextField.swift's
// event-classification logic, but for a multi-line UITextView with the
// STANDARD system keyboard (autocorrect/predictive/capitalization left ON —
// the research goal here is "how they use the standard keyboard", the
// opposite of LoggingTextField which disables all of that).
struct FreeWritingTextView: UIViewRepresentable {
    @Binding var text: String
    // params: textBefore, textAfter, replacementString, rangeStart, rangeLength, eventType
    var onEvent: (String, String, String, Int, Int, InputEventType) -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.isScrollEnabled = true
        tv.font = UIFont.systemFont(ofSize: 20)
        tv.keyboardType = .default
        // Intentionally left at system defaults (do NOT disable):
        // autocorrectionType, autocapitalizationType, spellCheckingType,
        // smartQuotesType, smartDashesType.
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: FreeWritingTextView

        init(_ parent: FreeWritingTextView) {
            self.parent = parent
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            let textBefore = textView.text ?? ""

            // Classify event (copied from LoggingTextField's classification)
            let eventType: InputEventType
            if text.isEmpty && range.length > 0 {
                eventType = .delete
            } else if text.count == 1 && range.length == 0 {
                eventType = .insert
            } else if text.count == 1 && range.length > 0 {
                eventType = .replace
            } else if text.count > 1 {
                eventType = .paste
            } else {
                // no-op (empty replacement with no range)
                return true
            }

            // Compute textAfter using NSString (UTF-16 offsets, matches the
            // delegate's NSRange) — required for correctness with emoji and
            // autocorrect's multi-char replacements.
            let nsTextBefore = textBefore as NSString
            let textAfter = nsTextBefore.replacingCharacters(in: range, with: text)

            parent.onEvent(textBefore, textAfter, text, range.location, range.length, eventType)

            // Return true so the system applies the change natively —
            // autocorrect/predictive text need native handling.
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
