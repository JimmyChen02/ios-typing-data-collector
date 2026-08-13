import SwiftUI

/// Full in-app analysis shown to researchers after every session and at study end.
struct ResearcherAnalysisPanel: View {
    var sessionManager: SessionManager

    @State private var plotLayout: TapDotPlotView.LayoutMode = .alpha
    @State private var gaussianPreviewImage: UIImage? = nil
    @State private var isRenderingGaussianPreview = false

    private var gaussianBoundaryEvents: [InputEventData] {
        GaussianBoundaryTimeline.finalGroundTruthEvents(from: sessionManager.allEvents)
    }

    private var classicSummaries: [StudySessionSummary] {
        sessionManager.studySessionSummaries.filter { $0.phase == StudyPhase.phaseA.rawValue }
    }

    private var gaussianSummaries: [StudySessionSummary] {
        sessionManager.studySessionSummaries.filter { $0.phase == StudyPhase.phaseB.rawValue }
    }

    var body: some View {
        VStack(spacing: 24) {
            if sessionManager.studyDesign == .classicAndAdaptive {
                studyComparison
            }
            sessionBreakdown
            cleaningSection
            if !gaussianBoundaryEvents.isEmpty {
                gaussianBoundarySection
            }
            tapPlotSection
            behaviorAnalyticsSection
        }
    }

    private func mean(_ vals: [Double]) -> Double {
        vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
    }

    private var studyComparison: some View {
        let cAcc = mean(classicSummaries.map(\.meanAccuracy))
        let gAcc = mean(gaussianSummaries.map(\.meanAccuracy))
        let cWPM = mean(classicSummaries.map(\.meanWPM))
        let gWPM = mean(gaussianSummaries.map(\.meanWPM))
        let cBksp = mean(classicSummaries.map { Double($0.totalBackspaces) })
        let gBksp = mean(gaussianSummaries.map { Double($0.totalBackspaces) })

        return VStack(spacing: 16) {
            Text("Classic vs Adaptive")
                .font(.title2).fontWeight(.bold)

            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text("Classic")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity)
                Text("Adaptive")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.teal)
                    .frame(maxWidth: .infinity)
                Text("Δ")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .frame(width: 64)
            }

            compRow(
                label: "Accuracy",
                cVal: String(format: "%.1f%%", cAcc * 100),
                gVal: String(format: "%.1f%%", gAcc * 100),
                delta: gAcc - cAcc,
                deltaFmt: { String(format: "%+.1f%%", $0 * 100) },
                higherBetter: true
            )
            compRow(
                label: "WPM",
                cVal: String(format: "%.1f", cWPM),
                gVal: String(format: "%.1f", gWPM),
                delta: gWPM - cWPM,
                deltaFmt: { String(format: "%+.1f", $0) },
                higherBetter: true
            )
            compRow(
                label: "Backspaces",
                cVal: String(format: "%.1f", cBksp),
                gVal: String(format: "%.1f", gBksp),
                delta: gBksp - cBksp,
                deltaFmt: { String(format: "%+.1f", $0) },
                higherBetter: false
            )
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemGray6)))
    }

    private func compRow(
        label: String,
        cVal: String,
        gVal: String,
        delta: Double,
        deltaFmt: (Double) -> String,
        higherBetter: Bool
    ) -> some View {
        let improved = higherBetter ? delta > 0 : delta < 0
        let deltaColor: Color = abs(delta) < 0.001 ? .secondary : (improved ? .green : .red)
        return HStack {
            Text(label)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(cVal)
                .font(.subheadline).fontWeight(.medium)
                .frame(maxWidth: .infinity)
            Text(gVal)
                .font(.subheadline).fontWeight(.medium)
                .frame(maxWidth: .infinity)
            Text(deltaFmt(delta))
                .font(.subheadline).fontWeight(.semibold)
                .foregroundColor(deltaColor)
                .frame(width: 64)
        }
    }

    private var sessionBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session by Session")
                .font(.headline)
            ForEach(Array(sessionManager.studySessionSummaries.enumerated()), id: \.element.id) { position, s in
                let isGaussian = s.mode == "gaussian"
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("S\(position + 1)")
                            .font(.caption).fontWeight(.bold)
                            .foregroundColor(isGaussian ? .teal : .orange)
                        Text("\(s.phase) · \(s.posture ?? (isGaussian ? "Adaptive" : "Classic"))")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 52, alignment: .leading)
                    Spacer()
                    miniStat(label: "Acc", value: String(format: "%.1f%%", s.meanAccuracy * 100))
                    miniStat(label: "WPM", value: String(format: "%.1f", s.meanWPM))
                    miniStat(label: "Bksp", value: "\(s.totalBackspaces)")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isGaussian ? Color.teal.opacity(0.08) : Color.orange.opacity(0.08))
                )
            }
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline).fontWeight(.semibold)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(minWidth: 48)
    }

    private var cleaningSection: some View {
        let summaries = sessionManager.studySessionSummaries
        let totalInserts = summaries.map(\.totalInserts).reduce(0, +)
        let uniqueFlagged = summaries.map(\.uniqueFlaggedInserts).reduce(0, +)
        let cleanCount = totalInserts - uniqueFlagged
        var combined: [String: Int] = [:]
        for s in summaries {
            for (flag, count) in s.flagCounts {
                combined[flag, default: 0] += count
            }
        }
        let flagOrder: [(key: String, label: String)] = [
            ("spatial", "Outside key bounds"),
            ("far_from_target", "Far from expected key"),
            ("iki_low", "Too fast  (< 50 ms)"),
            ("iki_high", "Too slow  (> 3 s)"),
            ("trial_start", "First keystroke of trial"),
        ]

        return VStack(alignment: .leading, spacing: 12) {
            Text("Data Cleaning")
                .font(.headline)
            HStack(spacing: 0) {
                cleanPill(value: "\(totalInserts)", label: "Total inserts", color: .primary)
                Spacer()
                cleanPill(
                    value: "\(uniqueFlagged)",
                    label: "Flagged (\(pct(uniqueFlagged, of: totalInserts)))",
                    color: .red
                )
                Spacer()
                cleanPill(
                    value: "\(cleanCount)",
                    label: "Clean (\(pct(cleanCount, of: totalInserts)))",
                    color: .green
                )
            }
            .padding(.vertical, 4)
            Divider()
            VStack(spacing: 6) {
                HStack {
                    Text("Flag").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Count").fontWeight(.semibold).frame(width: 48, alignment: .trailing)
                    Text("Rate").fontWeight(.semibold).frame(width: 52, alignment: .trailing)
                }
                .foregroundColor(.secondary)
                .font(.system(size: 11))
                ForEach(flagOrder, id: \.key) { item in
                    let count = combined[item.key] ?? 0
                    flagRow(label: item.label, count: count, total: totalInserts)
                }
            }
            .font(.system(size: 13))
            Text("A tap can carry multiple flags. Rates are per insert event.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemGray6)))
    }

    private func pct(_ n: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        return String(format: "%.1f%%", Double(n) / Double(total) * 100)
    }

    private func cleanPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3).fontWeight(.bold).foregroundColor(color)
            Text(label).font(.system(size: 10)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func flagRow(label: String, count: Int, total: Int) -> some View {
        let rate = total > 0 ? Double(count) / Double(total) : 0
        let barW = min(CGFloat(rate) * 200, 200)
        return HStack(spacing: 0) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            ZStack(alignment: .trailing) {
                Capsule().fill(Color(.systemGray4)).frame(width: 80, height: 5)
                Capsule().fill(rate > 0.1 ? Color.red : Color.orange)
                    .frame(width: barW * 0.4, height: 5)
            }
            .frame(width: 80)
            Text("\(count)").frame(width: 48, alignment: .trailing).foregroundColor(.secondary)
            Text(pct(count, of: total)).frame(width: 52, alignment: .trailing)
                .foregroundColor(rate > 0.1 ? .red : .primary)
        }
    }

    private var gaussianBoundarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gaussian boundaries")
                .font(.headline)
            Text("Cumulative boundary fit from classic sessions so far.")
                .font(.caption)
                .foregroundColor(.secondary)
            GeometryReader { geo in
                let width = max(280, geo.size.width)
                let height = max(220, width * 0.62)
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color(.systemGray6))
                    if let gaussianPreviewImage {
                        Image(uiImage: gaussianPreviewImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(8)
                    } else if isRenderingGaussianPreview {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Rendering Gaussian boundary...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("No Gaussian boundary preview available.")
                            .foregroundColor(.secondary)
                    }
                }
                .task(id: "\(Int(width.rounded()))-\(gaussianBoundaryEvents.count)") {
                    await renderGaussianBoundaryPreview(width: width, height: height)
                }
            }
            .frame(height: 230)
            Text("\(gaussianBoundaryEvents.count) clean classic taps")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var tapPlotSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tap Distribution")
                    .font(.headline)
                Spacer()
                Picker("Layout", selection: $plotLayout) {
                    ForEach(TapDotPlotView.LayoutMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            TapDotPlotView(
                events: sessionManager.allEvents,
                colorMode: .byKey,
                layoutMode: plotLayout
            )
        }
    }

    private var behaviorAnalyticsSection: some View {
        let events = sessionManager.allEvents
        let annotations = EditBehaviorAnnotator.annotate(events: events)
        let pairs = zip(events, annotations).map { ($0, $1) }
        let autocorrects = pairs.filter { $0.1.usedAutocorrect }
        let suggestions = pairs.filter { $0.1.usedSuggestion }
        let reverts = pairs.filter { $0.0.editSource == "correctionReversion" }
        let intentChanges = pairs.filter { !$0.1.intentPreserved }
        let cursorKinds = Dictionary(grouping: pairs.compactMap { pair -> String? in
            EditBehaviorAnnotator.cursorEditKind(for: pair.0)
        }, by: { $0 })

        return VStack(alignment: .leading, spacing: 16) {
            Text("Researcher Analytics")
                .font(.headline)
            HStack {
                analyticsPill(label: "LM autocorrect", value: "\(autocorrects.count)")
                analyticsPill(label: "Suggestion tap", value: "\(suggestions.count)")
                analyticsPill(label: "Cursor edits", value: "\(pairs.filter { $0.1.cursorMoved }.count)")
                analyticsPill(label: "Intent changes", value: "\(intentChanges.count)")
            }

            glossarySection

            typedTextSection(events: events)

            eventList(
                title: "Where LM autocorrect was used",
                empty: "No autocorrect replacements yet.",
                rows: autocorrects.suffix(20).map { event, ann in
                    let from = quote(ann.wrongfullyTypedToken.isEmpty ? event.originalText : ann.wrongfullyTypedToken)
                    let to = quote(ann.llmEditedToken.isEmpty ? event.emittedText : ann.llmEditedToken)
                    return "S\(event.studySessionIndex + 1): \(from) → \(to)"
                }
            )

            eventList(
                title: "Where a suggestion was tapped",
                empty: "No suggestion-bar taps yet.",
                rows: suggestions.suffix(20).map { event, _ in
                    let picked = event.selectedSuggestion.isEmpty ? event.emittedText : event.selectedSuggestion
                    let offered = event.suggestionsOffered.split(separator: "|").joined(separator: ", ")
                    return "S\(event.studySessionIndex + 1): chose \(quote(picked))"
                        + (offered.isEmpty ? "" : " from [\(offered)]")
                }
            )

            eventList(
                title: "Tapped a word to undo autocorrect",
                empty: "No word-tap reverts yet.",
                rows: reverts.suffix(12).map { event, _ in
                    "S\(event.studySessionIndex + 1): \(quote(event.originalText)) → \(quote(event.emittedText))"
                }
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Cursor and delete types")
                    .font(.subheadline.weight(.semibold))
                Text("We only see a cursor move when the next edit happens away from the end of the text. Pure caret movement with no typing is not a logged keystroke.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                cursorKindRow("Backspace at the end", count: cursorKinds["Backspace at the end"]?.count ?? 0)
                cursorKindRow("Backspace after moving the caret", count: cursorKinds["Backspace after moving the caret"]?.count ?? 0)
                cursorKindRow("Typed after moving the caret (tap or Space-trackpad)", count: cursorKinds["Typed after moving the caret (tap or Space-trackpad)"]?.count ?? 0)
                cursorKindRow("Tapped the underlined word", count: cursorKinds["Tapped the underlined word"]?.count ?? 0)
            }

            eventList(
                title: "Intent changes — what this means",
                empty: "No intent-change edits yet.",
                rows: intentChanges.suffix(16).map { event, ann in
                    let from = quote(ann.wrongfullyTypedToken.isEmpty ? event.originalText : ann.wrongfullyTypedToken)
                    let to = quote(ann.llmEditedToken.isEmpty ? event.emittedText : ann.llmEditedToken)
                    return "S\(event.studySessionIndex + 1) · \(EditBehaviorAnnotator.categoryTitle(ann.category)): \(from) → \(to)"
                }
            )

            if let snapshotDate = sessionManager.phaseBModelSnapshotDate {
                Text("Phase B snapshot: \(snapshotDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemGray6)))
    }

    private var glossarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What the labels mean")
                .font(.subheadline.weight(.semibold))
            glossaryRow("LM autocorrect", "The language model replaced a word after Space or Return, e.g. teh → the.")
            glossaryRow("Suggestion tap", "They tapped a word in the bar above the keys.")
            glossaryRow("Tapped a word", "They tapped the grey-underlined autocorrect to put the original letters back.")
            glossaryRow("Backspace at the end", "Delete while the caret was at the end of the text.")
            glossaryRow("Backspace after moving caret", "They moved the caret (tap in the text or long-press Space), then deleted.")
            glossaryRow("Typed after moving caret", "They placed the caret in the middle, then typed. We cannot tell tap-vs-trackpad unless they also deleted.")
            glossaryRow("Intent change", "The edit looks like they changed what they meant, not a small typo fix. Example: deleting a whole word and typing a different one. Same-intent is a nearby fix like recieve → receive.")
        }
        .font(.caption)
    }

    private func glossaryRow(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(body).foregroundColor(.secondary)
        }
    }

    private func typedTextSection(events: [InputEventData]) -> some View {
        let sessions = Dictionary(grouping: events, by: \.studySessionIndex)
            .sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 8) {
            Text("What they typed")
                .font(.subheadline.weight(.semibold))
            if sessions.isEmpty {
                Text("No typed text yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(sessions, id: \.key) { index, evs in
                    let text = evs.last?.textAfter.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session \(index + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        Text(text.isEmpty ? "(empty)" : text)
                            .font(.subheadline)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
                }
            }
        }
    }

    private func eventList(title: String, empty: String, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if rows.isEmpty {
                Text(empty)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .font(.caption)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    private func cursorKindRow(_ label: String, count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)")
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption)
    }

    private func quote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "“”" : "“\(trimmed)”"
    }

    private func analyticsPill(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func renderGaussianBoundaryPreview(width: CGFloat, height: CGFloat) async {
        let events = gaussianBoundaryEvents
        guard !events.isEmpty else {
            gaussianPreviewImage = nil
            isRenderingGaussianPreview = false
            return
        }
        isRenderingGaussianPreview = true
        let model = await Task.detached(priority: .userInitiated) {
            GaussianKeyModel.fit(events: events, keys: GaussianBoundaryTimeline.allKeys)
        }.value
        let image = await MainActor.run {
            GaussianKeyboardExporter().previewImage(
                model: model,
                overlayEvents: events,
                size: CGSize(width: width, height: height)
            )
        }
        gaussianPreviewImage = image
        isRenderingGaussianPreview = false
    }
}
