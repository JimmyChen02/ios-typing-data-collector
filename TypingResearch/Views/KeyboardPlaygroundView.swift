import SwiftUI

/// Keyboard-first playground: type freely, inspect LM suggestions/autocorrect,
/// and export a CSV of every edit. No Gaussian routing, no study timer.
struct KeyboardPlaygroundView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var typedText = ""
    @State private var caretUTF16 = 0
    @State private var selectionLengthUTF16 = 0
    @State private var events: [PlaygroundEvent] = []
    @State private var shareItem: ShareItem?
    @State private var statusMessage: String?
    @State private var keyboardSize = KeyboardSizeModel()
    @State private var revertible: RevertibleAutocorrection?

    private var kbBg: Color {
        colorScheme == .dark
            ? Color(red: 0.176, green: 0.176, blue: 0.184)
            : Color(red: 0.82, green: 0.835, blue: 0.86)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AnnotatedTypingCanvas(
                    text: $typedText,
                    caretUTF16: $caretUTF16,
                    selectionLengthUTF16: $selectionLengthUTF16,
                    revertible: revertible,
                    placeholder: "Start typing…"
                ) { mark in
                    revertAutocorrection(mark)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text("LM: SymSpell en-30k · long-press Space = move cursor")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(
                            "\(events.count) events · key \(Int(keyboardSize.layoutSpec.letterKeyWidth))×\(Int(keyboardSize.layoutSpec.rowHeight)) · \(Int(keyboardSize.contentHeight))pt"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        if let statusMessage {
                            Text(statusMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Button("Clear") {
                            typedText = ""
                            caretUTF16 = 0
                            selectionLengthUTF16 = 0
                            events = []
                            revertible = nil
                            statusMessage = nil
                        }
                        .font(.caption.weight(.semibold))
                        Button("Export CSV") { exportCSV() }
                            .font(.caption.weight(.semibold))
                            .disabled(events.isEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                InAppResearchKeyboardView(
                    text: typedText,
                    caretUTF16: $caretUTF16,
                    selectionLengthUTF16: $selectionLengthUTF16
                ) { edits in
                    handle(edits)
                }
                .frame(height: keyboardSize.contentHeight)
            }
            .background(alignment: .bottom) {
                kbBg
                    .frame(height: keyboardSize.totalDockedHeight)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(activityItems: item.urls)
            }
            .onAppear {
                SystemKeyboardMetrics.ensureMeasured()
                keyboardSize.refresh()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            ) { _ in
                keyboardSize.refresh()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: SystemKeyboardMetrics.didUpdateNotification)
            ) { _ in
                keyboardSize.refresh()
            }
        }
    }

    private func handle(_ edits: [InAppKeyboardEdit]) {
        var newRevertible: RevertibleAutocorrection?

        for edit in edits {
            apply(edit)

            if edit.source == .autocorrection, edit.kind == .replace {
                let replacement = edit.emittedText
                let loc = caretUTF16 - (replacement as NSString).length
                if loc >= 0 {
                    newRevertible = RevertibleAutocorrection(
                        original: edit.originalText,
                        replacement: replacement,
                        utf16Location: loc
                    )
                }
            }

            let gestureJSON: String = {
                guard let gesture = edit.gesture,
                      let data = try? JSONEncoder().encode(gesture),
                      let string = String(data: data, encoding: .utf8) else { return "" }
                return string
            }()

            events.append(
                PlaygroundEvent(
                    timestamp: Date(),
                    eventType: {
                        switch edit.kind {
                        case .insert: return "insert"
                        case .delete: return "delete"
                        case .replace: return "replace"
                        }
                    }(),
                    source: edit.source.rawValue,
                    originalText: edit.originalText,
                    emittedText: edit.emittedText,
                    textAfter: typedText,
                    keyLabel: edit.tapInfo.keyLabel,
                    tapLocalX: edit.tapInfo.tapLocalX,
                    tapLocalY: edit.tapInfo.tapLocalY,
                    keyWidth: edit.tapInfo.keyWidth,
                    keyHeight: edit.tapInfo.keyHeight,
                    suggestionsOffered: edit.suggestionsOffered.joined(separator: "|"),
                    selectedSuggestion: edit.selectedSuggestion ?? "",
                    touchGestureJSON: gestureJSON
                )
            )
        }

        if let newRevertible {
            revertible = newRevertible
        } else {
            let onlyWhitespaceAfterCorrection = edits.allSatisfy { edit in
                if edit.source == .autocorrection { return true }
                return edit.kind == .insert
                    && (edit.emittedText == " " || edit.emittedText == "\n")
            }
            if !onlyWhitespaceAfterCorrection {
                revertible = nil
            }
        }
    }

    private func apply(_ edit: InAppKeyboardEdit) {
        let ns = typedText as NSString
        let caret = max(0, min(caretUTF16, ns.length))

        switch edit.kind {
        case .insert:
            let sel = max(0, min(selectionLengthUTF16, ns.length - caret))
            typedText = ns.replacingCharacters(
                in: NSRange(location: caret, length: sel),
                with: edit.emittedText
            )
            caretUTF16 = caret + (edit.emittedText as NSString).length

        case .delete:
            let delLen = (edit.originalText as NSString).length
            guard delLen > 0 else { return }
            let loc: Int
            let atCaret = NSRange(location: caret, length: delLen)
            if NSMaxRange(atCaret) <= ns.length, ns.substring(with: atCaret) == edit.originalText {
                loc = caret
            } else if caret >= delLen {
                loc = caret - delLen
                guard ns.substring(with: NSRange(location: loc, length: delLen)) == edit.originalText else {
                    return
                }
            } else {
                return
            }
            typedText = ns.replacingCharacters(
                in: NSRange(location: loc, length: delLen),
                with: ""
            )
            caretUTF16 = loc

        case .replace:
            let origLen = (edit.originalText as NSString).length
            let loc: Int
            let atCaret = NSRange(location: caret, length: origLen)
            if origLen > 0,
               NSMaxRange(atCaret) <= ns.length,
               ns.substring(with: atCaret) == edit.originalText {
                loc = caret
            } else {
                loc = max(0, caret - origLen)
            }
            typedText = ns.replacingCharacters(
                in: NSRange(location: loc, length: origLen),
                with: edit.emittedText
            )
            caretUTF16 = loc + (edit.emittedText as NSString).length
        }
        selectionLengthUTF16 = 0
    }

    private func revertAutocorrection(_ mark: RevertibleAutocorrection) {
        let ns = typedText as NSString
        let range = NSRange(
            location: mark.utf16Location,
            length: (mark.replacement as NSString).length
        )
        guard range.location >= 0,
              NSMaxRange(range) <= ns.length,
              ns.substring(with: range) == mark.replacement else {
            revertible = nil
            return
        }

        typedText = ns.replacingCharacters(in: range, with: mark.original)
        caretUTF16 = range.location + (mark.original as NSString).length
        revertible = nil
        statusMessage = "Reverted to \"\(mark.original)\""

        events.append(
            PlaygroundEvent(
                timestamp: Date(),
                eventType: "replace",
                source: EditSource.correctionReversion.rawValue,
                originalText: mark.replacement,
                emittedText: mark.original,
                textAfter: typedText,
                keyLabel: "",
                tapLocalX: 0,
                tapLocalY: 0,
                keyWidth: 0,
                keyHeight: 0,
                suggestionsOffered: "",
                selectedSuggestion: mark.original,
                touchGestureJSON: ""
            )
        )
    }

    private func exportCSV() {
        var rows = [
            [
                "timestamp_iso", "event_type", "edit_source",
                "original_text", "emitted_text", "text_after",
                "key_label", "tap_local_x", "tap_local_y", "key_width", "key_height",
                "suggestions_offered", "selected_suggestion", "touch_gesture_json"
            ].joined(separator: ",")
        ]
        let iso = ISO8601DateFormatter()
        for event in events {
            rows.append([
                csvEscape(iso.string(from: event.timestamp)),
                csvEscape(event.eventType),
                csvEscape(event.source),
                csvEscape(event.originalText),
                csvEscape(event.emittedText),
                csvEscape(event.textAfter),
                csvEscape(event.keyLabel),
                String(format: "%.4f", event.tapLocalX),
                String(format: "%.4f", event.tapLocalY),
                String(format: "%.4f", event.keyWidth),
                String(format: "%.4f", event.keyHeight),
                csvEscape(event.suggestionsOffered),
                csvEscape(event.selectedSuggestion),
                csvEscape(event.touchGestureJSON)
            ].joined(separator: ","))
        }

        let name = "keyboard_playground_\(Int(Date().timeIntervalSince1970)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareItem(url: url)
            statusMessage = "CSV ready"
        } catch {
            statusMessage = "Export failed"
        }
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

private struct PlaygroundEvent {
    let timestamp: Date
    let eventType: String
    let source: String
    let originalText: String
    let emittedText: String
    let textAfter: String
    let keyLabel: String
    let tapLocalX: Double
    let tapLocalY: Double
    let keyWidth: Double
    let keyHeight: Double
    let suggestionsOffered: String
    let selectedSuggestion: String
    let touchGestureJSON: String
}
