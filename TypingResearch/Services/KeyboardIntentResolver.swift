import Foundation

/// Infers, for each letter tap, which key boundary that tap should train.
///
/// Free typing has no prompt, so "intended letter" is recovered from what
/// happened to the word: kept as typed, fixed as a typo, accepted/rejected LM
/// replacement, or abandoned because the user changed the word entirely.
enum KeyboardIntentResolver {

    enum Kind: String, Sendable {
        case keptAsTyped
        case typoFixSameWord
        case lmAccepted
        case lmReverted
        case lmWrongUserFixed
        case changedMind
        case notALetter
    }

    struct Resolution: Sendable {
        var intendedKey: [Int: String] = [:]
        var note: [Int: String] = [:]
        var typedWord: [Int: String] = [:]
        var finalWord: [Int: String] = [:]
        var lmWord: [Int: String] = [:]
        var tapKind: [Int: Kind] = [:]
        var eventKind: [Int: Kind] = [:]
    }

    static func resolve(events: [InputEventData]) -> Resolution {
        var result = Resolution()
        var liveTaps: [Int] = []
        var peakTaps: [Int] = []
        var abandonedTaps: [Int] = []

        for (idx, event) in events.enumerated() {
            if isLetterTap(event) {
                result.intendedKey[idx] = letter(from: event.actualChar) ?? ""
                result.tapKind[idx] = .keptAsTyped
                result.note[idx] = "Kept as typed → train \(result.intendedKey[idx] ?? "")"
                liveTaps.append(idx)
                if liveTaps.count >= peakTaps.count {
                    peakTaps = liveTaps
                }
                continue
            }

            if event.eventType == .delete {
                popDeletedLetters(event.originalText.isEmpty ? event.correctedChar : event.originalText,
                                  from: &liveTaps,
                                  events: events)
                if liveTaps.isEmpty, !peakTaps.isEmpty {
                    abandonedTaps = peakTaps
                    peakTaps = []
                }
                continue
            }

            if event.editSource == "autocorrection" || event.editSource == "candidate" {
                let typed = normalized(
                    event.originalText.isEmpty
                        ? letters(from: peakTaps.isEmpty ? liveTaps : peakTaps, events: events)
                        : event.originalText
                )
                let lm = normalized(event.emittedText)
                let taps = peakTaps.isEmpty ? liveTaps : peakTaps
                let aftermath = lookAheadAfterLM(from: idx, typed: typed, lm: lm, events: events)
                applyWordOutcome(
                    taps: taps.isEmpty ? letterTaps(in: typed, before: idx, events: events) : taps,
                    typed: typed,
                    lm: lm,
                    final: aftermath.word,
                    kind: aftermath.kind,
                    resolvingEvent: aftermath.eventIndex ?? idx,
                    events: events,
                    into: &result
                )
                liveTaps = []
                peakTaps = []
                abandonedTaps = []
                continue
            }

            if event.editSource == "correctionReversion" {
                result.eventKind[idx] = .lmReverted
                continue
            }

            if isWordCommit(event) {
                commitCurrentWord(
                    liveTaps: liveTaps,
                    peakTaps: peakTaps,
                    abandonedTaps: abandonedTaps,
                    resolvingEvent: idx,
                    events: events,
                    into: &result
                )
                liveTaps = []
                peakTaps = []
                abandonedTaps = []
            }
        }

        if !liveTaps.isEmpty || !peakTaps.isEmpty || !abandonedTaps.isEmpty {
            commitCurrentWord(
                liveTaps: liveTaps,
                peakTaps: peakTaps,
                abandonedTaps: abandonedTaps,
                resolvingEvent: max(events.count - 1, 0),
                events: events,
                into: &result
            )
        }

        return result
    }

    private static func commitCurrentWord(
        liveTaps: [Int],
        peakTaps: [Int],
        abandonedTaps: [Int],
        resolvingEvent: Int,
        events: [InputEventData],
        into result: inout Resolution
    ) {
        let final = letters(from: liveTaps, events: events)
        if !abandonedTaps.isEmpty {
            let typed = letters(from: abandonedTaps, events: events)
            applyWordOutcome(
                taps: abandonedTaps,
                typed: typed,
                lm: nil,
                final: final,
                kind: classify(typed: typed, lm: nil, final: final),
                resolvingEvent: resolvingEvent,
                events: events,
                into: &result
            )
            if !liveTaps.isEmpty {
                applyWordOutcome(
                    taps: liveTaps,
                    typed: final,
                    lm: nil,
                    final: final,
                    kind: .keptAsTyped,
                    resolvingEvent: resolvingEvent,
                    events: events,
                    into: &result
                )
            }
            return
        }

        let taps = peakTaps.isEmpty ? liveTaps : peakTaps
        guard !taps.isEmpty else { return }
        let typed = letters(from: taps, events: events)
        let kind = classify(typed: typed, lm: nil, final: final.isEmpty ? typed : final)
        applyWordOutcome(
            taps: taps,
            typed: typed,
            lm: nil,
            final: final.isEmpty ? typed : final,
            kind: kind,
            resolvingEvent: resolvingEvent,
            events: events,
            into: &result
        )
    }

    // MARK: - Word outcome

    private struct Aftermath {
        var word: String
        var kind: Kind
        var eventIndex: Int?
    }

    private static func lookAheadAfterLM(
        from lmIndex: Int,
        typed: String,
        lm: String,
        events: [InputEventData]
    ) -> Aftermath {
        var word = lm
        var lastEdit: Int?
        var i = lmIndex + 1
        while i < events.count {
            let event = events[i]
            if event.editSource == "correctionReversion" {
                let from = normalized(event.originalText)
                if from == word || from == lm {
                    return Aftermath(word: normalized(event.emittedText), kind: .lmReverted, eventIndex: i)
                }
            }

            let beforeToken = token(at: event.rangeStart, in: event.textBefore)
            let afterToken = token(at: event.rangeStart, in: event.textAfter)
            let touchesLMWord = !word.isEmpty && (
                normalized(beforeToken) == word
                || normalized(beforeToken).hasPrefix(word)
                || word.hasPrefix(normalized(beforeToken))
            )

            if touchesLMWord, !afterToken.isEmpty {
                let next = normalized(afterToken)
                if next != word {
                    word = next
                    lastEdit = i
                }
            }

            if isWordCommit(event), lastEdit != nil {
                break
            }
            if event.editSource == "key",
               event.eventType == .insert,
               event.rangeStart >= (event.textBefore as NSString).length,
               event.textBefore.last?.isWhitespace == true,
               lastEdit != nil {
                break
            }
            i += 1
        }

        let kind = classify(typed: typed, lm: lm, final: word)
        return Aftermath(word: word, kind: kind, eventIndex: lastEdit)
    }

    static func classify(typed: String, lm: String?, final: String) -> Kind {
        let typedN = normalized(typed)
        let finalN = normalized(final)
        if typedN.isEmpty && finalN.isEmpty { return .notALetter }
        if let lm, !lm.isEmpty {
            let lmN = normalized(lm)
            if finalN == typedN { return .lmReverted }
            if finalN == lmN { return .lmAccepted }
            let dTyped = levenshtein(finalN, typedN)
            let dLM = levenshtein(finalN, lmN)
            if isClose(dTyped, word: typedN) && dTyped <= dLM { return .lmWrongUserFixed }
            if isClose(dLM, word: lmN) { return .lmAccepted }
            return .changedMind
        }
        if finalN == typedN { return .keptAsTyped }
        if isClose(levenshtein(finalN, typedN), word: typedN) { return .typoFixSameWord }
        return .changedMind
    }

    private static func applyWordOutcome(
        taps: [Int],
        typed: String,
        lm: String?,
        final: String,
        kind: Kind,
        resolvingEvent: Int,
        events: [InputEventData],
        into result: inout Resolution
    ) {
        result.eventKind[resolvingEvent] = kind
        result.typedWord[resolvingEvent] = normalized(typed)
        result.finalWord[resolvingEvent] = normalized(final)
        if let lm { result.lmWord[resolvingEvent] = normalized(lm) }
        result.note[resolvingEvent] = note(
            for: kind,
            typed: normalized(typed),
            lm: lm,
            final: normalized(final),
            intended: ""
        )
        let target: String
        switch kind {
        case .lmAccepted:
            target = normalized(lm ?? final)
        case .lmReverted, .lmWrongUserFixed, .typoFixSameWord, .keptAsTyped:
            target = normalized(final.isEmpty ? typed : final)
        case .changedMind, .notALetter:
            target = ""
        }

        let typedLetters = letters(from: taps, events: events)
        let alignment = alignTypedToTarget(typedLetters, target)

        for (offset, tap) in taps.enumerated() {
            result.typedWord[tap] = typedLetters
            result.finalWord[tap] = target
            if let lm { result.lmWord[tap] = lm }
            result.tapKind[tap] = kind
            if kind == .changedMind || target.isEmpty {
                result.intendedKey[tap] = ""
                result.note[tap] = "Changed the word (\(typedLetters) → \(normalized(final))) → skip this tap"
                continue
            }
            let aligned = offset < alignment.count ? alignment[offset] : nil
            if let letter = aligned, isLetter(letter) {
                result.intendedKey[tap] = letter
                result.note[tap] = note(for: kind, typed: typedLetters, lm: lm, final: target, intended: letter)
            } else {
                result.intendedKey[tap] = ""
                result.note[tap] = "Extra letter in \(typedLetters), not in \(target) → skip"
            }
        }
    }

    private static func note(
        for kind: Kind,
        typed: String,
        lm: String?,
        final: String,
        intended: String
    ) -> String {
        switch kind {
        case .keptAsTyped:
            return "Typed \(typed) and kept it → train \(intended)"
        case .typoFixSameWord:
            return "Typo fix \(typed) → \(final) → train \(intended)"
        case .lmAccepted:
            return "LM kept \(typed) → \(lm ?? final) → train \(intended)"
        case .lmReverted:
            return "Undid LM \(lm ?? "") → \(typed) → train \(intended)"
        case .lmWrongUserFixed:
            if intended.isEmpty {
                return "LM was wrong (\(typed) → \(lm ?? "")), user fixed to \(final)"
            }
            return "LM was wrong (\(typed) → \(lm ?? "")), user fixed to \(final) → train \(intended)"
        case .changedMind:
            return "Changed meaning → skip"
        case .notALetter:
            return ""
        }
    }

    // MARK: - Helpers

    private static func isLetterTap(_ event: InputEventData) -> Bool {
        guard event.editSource == "key" else { return false }
        guard event.eventType == .insert || event.eventType == .replace else { return false }
        return letter(from: event.actualChar) != nil
    }

    private static func isWordCommit(_ event: InputEventData) -> Bool {
        event.emittedText == " " || event.emittedText == "\n"
    }

    private static func letter(from raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard key.count == 1, let ch = key.first, ch.isLetter else { return nil }
        return String(ch)
    }

    private static func isLetter(_ raw: String) -> Bool {
        letter(from: raw) != nil
    }

    private static func normalized(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func letters(from taps: [Int], events: [InputEventData]) -> String {
        taps.compactMap { letter(from: events[$0].actualChar) }.joined()
    }

    private static func popDeletedLetters(
        _ deleted: String,
        from wordTaps: inout [Int],
        events: [InputEventData]
    ) {
        for ch in deleted.lowercased().reversed() {
            guard ch.isLetter, let last = wordTaps.last else { continue }
            if letter(from: events[last].actualChar) == String(ch) {
                wordTaps.removeLast()
            }
        }
    }

    private static func letterTaps(
        in word: String,
        before index: Int,
        events: [InputEventData]
    ) -> [Int] {
        var remaining = Array(normalized(word))
        var taps: [Int] = []
        var i = index - 1
        while i >= 0, !remaining.isEmpty {
            if isLetterTap(events[i]),
               let ch = letter(from: events[i].actualChar),
               remaining.last == Character(ch) {
                remaining.removeLast()
                taps.append(i)
            }
            i -= 1
        }
        return taps.reversed()
    }

    private static func token(at utf16: Int, in text: String) -> String {
        let ns = text as NSString
        guard ns.length > 0 else { return "" }
        var loc = max(0, min(utf16, ns.length))
        if loc == ns.length { loc = max(0, loc - 1) }
        var start = loc
        var end = loc
        while start > 0 {
            let ch = ns.character(at: start - 1)
            if ch == 32 || ch == 9 || ch == 10 { break }
            start -= 1
        }
        while end < ns.length {
            let ch = ns.character(at: end)
            if ch == 32 || ch == 9 || ch == 10 { break }
            end += 1
        }
        guard end > start else { return "" }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private static func isClose(_ distance: Int, word: String) -> Bool {
        // At least 2 so short swaps like teh → the count as the same word.
        let limit = max(2, max(word.count, 1) / 3)
        return distance <= limit
    }

    static func alignTypedToTarget(_ typed: String, _ target: String) -> [String?] {
        let a = Array(typed.lowercased())
        let b = Array(target.lowercased())
        let n = a.count
        let m = b.count
        if n == 0 { return [] }
        if m == 0 { return Array(repeating: nil, count: n) }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = min(dp[i - 1][j - 1], dp[i - 1][j], dp[i][j - 1]) + 1
                }
            }
        }

        var i = n
        var j = m
        var result = Array(repeating: Optional<String>.none, count: n)
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                result[i - 1] = String(b[j - 1])
                i -= 1
                j -= 1
            } else if i > 0, j > 0, dp[i][j] == dp[i - 1][j - 1] + 1 {
                result[i - 1] = String(b[j - 1])
                i -= 1
                j -= 1
            } else if i > 0, j == 0 || dp[i][j] == dp[i - 1][j] + 1 {
                result[i - 1] = nil
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let sa = Array(a)
        let sb = Array(b)
        if sa.isEmpty { return sb.count }
        if sb.isEmpty { return sa.count }
        var dp = Array(0...sb.count)
        for i in 1...sa.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...sb.count {
                let temp = dp[j]
                if sa[i - 1] == sb[j - 1] {
                    dp[j] = prev
                } else {
                    dp[j] = min(prev + 1, dp[j] + 1, dp[j - 1] + 1)
                }
                prev = temp
            }
        }
        return dp[sb.count]
    }
}
