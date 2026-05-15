import Charts
import SwiftUI

struct SessionView: View {
    var sessionManager: SessionManager

    var body: some View {
        Group {
            if sessionManager.isStudyComplete {
                SummaryView(sessionManager: sessionManager)
            } else if sessionManager.isSessionComplete {
                BetweenSessionView(sessionManager: sessionManager)
            } else if sessionManager.isTrialActive {
                TrialView(
                    sessionManager: sessionManager,
                    onTrialComplete: handleTrialComplete
                )
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading next session...")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    private func handleTrialComplete() {
        if !sessionManager.isSessionComplete {
            sessionManager.startNextTrial()
        }
    }
}

// MARK: - SummaryView

struct SummaryView: View {
    var sessionManager: SessionManager
    @State private var shareItem: ShareItem? = nil
    @State private var showResetConfirm: Bool = false
    @State private var generatingPDF: PDFKind? = nil
    @State private var plotLayout: TapDotPlotView.LayoutMode = .alpha
    @State private var groundTruthAnalysis: GroundTruthLossAnalysis? = nil
    @State private var groundTruthError: String? = nil
    @State private var isLoadingGroundTruth: Bool = false

    private enum PDFKind { case raw, cleaned, gaussian }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if sessionManager.studyDesign == .classicAndAdaptive {
                        studyComparison
                        Divider()
                    }
                    sessionBreakdown
                    Divider()
                    cleaningSection
                    Divider()
                    groundTruthLossSection
                    Divider()
                    tapPlotSection
                    Divider()
                    exportButtons
                }
                .padding()
            }
            .task {
                await loadGroundTruthAnalysisIfNeeded()
            }
            .navigationTitle(sessionManager.studyDesign == .classicOnly ? "Collection Complete" : "Study Complete")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("New Study") { showResetConfirm = true }
                        .foregroundColor(.orange)
                }
            }
            .confirmationDialog("Start a new study?",
                                isPresented: $showResetConfirm,
                                titleVisibility: .visible) {
                Button("Same participant") { sessionManager.restartSameSession() }
                Button("New participant", role: .destructive) { sessionManager.reset() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Study Comparison

    private var classicSummaries: [StudySessionSummary] {
        sessionManager.studySessionSummaries.filter { $0.mode == "classic" }
    }
    private var gaussianSummaries: [StudySessionSummary] {
        sessionManager.studySessionSummaries.filter { $0.mode == "gaussian" }
    }
    private func mean(_ vals: [Double]) -> Double {
        vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
    }

    private var studyComparison: some View {
        let cAcc  = mean(classicSummaries.map(\.meanAccuracy))
        let gAcc  = mean(gaussianSummaries.map(\.meanAccuracy))
        let cWPM  = mean(classicSummaries.map(\.meanWPM))
        let gWPM  = mean(gaussianSummaries.map(\.meanWPM))
        let cBksp = mean(classicSummaries.map { Double($0.totalBackspaces) })
        let gBksp = mean(gaussianSummaries.map { Double($0.totalBackspaces) })

        return VStack(spacing: 16) {
            Text("Classic vs Adaptive")
                .font(.title2).fontWeight(.bold)

            // Column headers
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

            compRow(label: "Accuracy",
                    cVal: String(format: "%.1f%%", cAcc * 100),
                    gVal: String(format: "%.1f%%", gAcc * 100),
                    delta: gAcc - cAcc,
                    deltaFmt: { String(format: "%+.1f%%", $0 * 100) },
                    higherBetter: true)

            compRow(label: "WPM",
                    cVal: String(format: "%.1f", cWPM),
                    gVal: String(format: "%.1f", gWPM),
                    delta: gWPM - cWPM,
                    deltaFmt: { String(format: "%+.1f", $0) },
                    higherBetter: true)

            compRow(label: "Backspaces",
                    cVal: String(format: "%.1f", cBksp),
                    gVal: String(format: "%.1f", gBksp),
                    delta: gBksp - cBksp,
                    deltaFmt: { String(format: "%+.1f", $0) },
                    higherBetter: false)
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

    // MARK: - Per-Session Breakdown

    private var sessionBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session by Session")
                .font(.headline)

            ForEach(sessionManager.studySessionSummaries, id: \.sessionIndex) { s in
                let isGaussian = s.mode == "gaussian"
                HStack(spacing: 12) {
                    // Session label
                    VStack(alignment: .leading, spacing: 2) {
                        Text("S\(s.sessionIndex + 1)")
                            .font(.caption).fontWeight(.bold)
                            .foregroundColor(isGaussian ? .teal : .orange)
                        Text(isGaussian ? "Adaptive" : "Classic")
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

    // MARK: - Cleaning Section

    private var cleaningSection: some View {
        let summaries = sessionManager.studySessionSummaries
        let totalInserts    = summaries.map(\.totalInserts).reduce(0, +)
        let uniqueFlagged   = summaries.map(\.uniqueFlaggedInserts).reduce(0, +)
        let cleanCount      = totalInserts - uniqueFlagged

        // Aggregate flag counts across all sessions
        var combined: [String: Int] = [:]
        for s in summaries {
            for (flag, count) in s.flagCounts {
                combined[flag, default: 0] += count
            }
        }

        // Display order and labels
        let flagOrder: [(key: String, label: String)] = [
            ("spatial",         "Outside key bounds"),
            ("far_from_target", "Far from expected key"),
            ("iki_low",         "Too fast  (< 50 ms)"),
            ("iki_high",        "Too slow  (> 3 s)"),
            ("trial_start",     "First keystroke of trial"),
        ]

        return VStack(alignment: .leading, spacing: 12) {
            Text("Data Cleaning")
                .font(.headline)

            // Top-line numbers
            HStack(spacing: 0) {
                cleanPill(value: "\(totalInserts)", label: "Total inserts", color: .primary)
                Spacer()
                cleanPill(value: "\(uniqueFlagged)",
                          label: "Flagged (\(pct(uniqueFlagged, of: totalInserts)))",
                          color: .red)
                Spacer()
                cleanPill(value: "\(cleanCount)",
                          label: "Clean (\(pct(cleanCount, of: totalInserts)))",
                          color: .green)
            }
            .padding(.vertical, 4)

            Divider()

            // Per-flag breakdown
            VStack(spacing: 6) {
                flagHeaderRow()
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

    @ViewBuilder
    private func flagHeaderRow() -> some View {
        HStack {
            Text("Flag").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
            Text("Count").fontWeight(.semibold).frame(width: 48, alignment: .trailing)
            Text("Rate").fontWeight(.semibold).frame(width: 52, alignment: .trailing)
        }
        .foregroundColor(.secondary)
        .font(.system(size: 11))
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

    // MARK: - Tap Plot Section

    private var groundTruthLossSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ground Truth Loss")
                .font(.headline)

            Text("Computed automatically from clean classic-session insert taps. Prefix mode shows one specific cumulative path; all-combinations mode averages across every subset of the same size.")
                .font(.caption)
                .foregroundColor(.secondary)

            if isLoadingGroundTruth {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Computing ground-truth loss curves...")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else if let groundTruthError {
                Text(groundTruthError)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else if let analysis = groundTruthAnalysis {
                Text("\(analysis.totalTrials) classic trials, \(analysis.usableEventCount) clean insert events")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 20) {
                    chartSection(
                        title: "Specific Cumulative Path",
                        subtitle: "{1}, {1,2}, {1,2,3}, ... compared with all classic trials",
                        points: analysis.simpleSummary
                    )

                    chartSection(
                        title: "Average Across All Combinations",
                        subtitle: "Mean over every same-size subset before comparing with all classic trials",
                        points: analysis.allCombinationsSummary
                    )
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemGray6)))
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

            NavigationLink {
                SessionOverlapView(events: sessionManager.allEvents)
            } label: {
                Label("Open Session Overlap Viewer", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func chartSection(
        title: String,
        subtitle: String,
        points: [GroundTruthSeriesPoint]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)

            groundTruthCard(title: "Loss and Mean Loss") {
                lossChart(points: points)
            }

            groundTruthCard(title: "Similarity") {
                similarityChart(points: points)
            }
        }
    }

    @ViewBuilder
    private func groundTruthCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            content()
                .frame(height: 220)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
        )
    }

    private func lossChart(points: [GroundTruthSeriesPoint]) -> some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Trials", point.numTrials),
                    y: .value("Value", point.loss)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(by: .value("Metric", "loss"))

                PointMark(
                    x: .value("Trials", point.numTrials),
                    y: .value("Value", point.loss)
                )
                .foregroundStyle(by: .value("Metric", "loss"))

                LineMark(
                    x: .value("Trials", point.numTrials),
                    y: .value("Value", point.meanLoss)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(by: .value("Metric", "mean_loss"))

                PointMark(
                    x: .value("Trials", point.numTrials),
                    y: .value("Value", point.meanLoss)
                )
                .foregroundStyle(by: .value("Metric", "mean_loss"))
            }
        }
        .chartForegroundStyleScale([
            "loss": Color.pink,
            "mean_loss": Color.purple,
        ])
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: .stride(by: 1))
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }

    private func similarityChart(points: [GroundTruthSeriesPoint]) -> some View {
        Chart(points) { point in
            LineMark(
                x: .value("Trials", point.numTrials),
                y: .value("Similarity", point.similarity)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(.teal)

            PointMark(
                x: .value("Trials", point.numTrials),
                y: .value("Similarity", point.similarity)
            )
            .foregroundStyle(.teal)
        }
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: .stride(by: 1))
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }

    // MARK: - Export Buttons

    private var exportButtons: some View {
        VStack(alignment: .leading, spacing: 16) {
            exportGroup(
                title: "Raw data",
                caption: "Every recorded keystroke.",
                csvAction: { exportCSV(cleaned: false) },
                csvLabel: "Raw Keystrokes CSV",
                pdfAction: { exportPDF(.raw) },
                pdfLabel: "Raw Keyboard View PDF",
                pdfKind: .raw
            )

            exportGroup(
                title: "Cleaned data",
                caption: "Outliers flagged; spatial + far-from-target taps dropped from the PDF.",
                csvAction: { exportCSV(cleaned: true) },
                csvLabel: "Cleaned Keystrokes CSV",
                pdfAction: { exportPDF(.cleaned) },
                pdfLabel: "Cleaned Keyboard View PDF",
                pdfKind: .cleaned
            )

            if sessionManager.sessionMode == .gaussian {
                gaussianExportGroup
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
    }

    private var gaussianExportGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gaussian boundaries")
                .font(.headline)
            Text("Per-key ellipses fit from classic sessions only.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: { exportGaussianPDF() }) {
                HStack {
                    if generatingPDF == .gaussian {
                        ProgressView().tint(.white).padding(.trailing, 4)
                    } else {
                        Image(systemName: "scope")
                    }
                    Text(generatingPDF == .gaussian ? "Generating\u{2026}"
                         : "Gaussian Boundaries PDF")
                }
                .frame(maxWidth: .infinity).padding()
                .background(Color.teal)
                .foregroundColor(.white).cornerRadius(10)
            }
            .disabled(generatingPDF != nil)
        }
    }

    @ViewBuilder
    private func exportGroup(
        title: String,
        caption: String,
        csvAction: @escaping () -> Void,
        csvLabel: String,
        pdfAction: @escaping () -> Void,
        pdfLabel: String,
        pdfKind: PDFKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: csvAction) {
                Label(csvLabel, systemImage: "keyboard")
                    .frame(maxWidth: .infinity).padding()
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary).cornerRadius(10)
            }

            Button(action: pdfAction) {
                HStack {
                    if generatingPDF == pdfKind {
                        ProgressView().tint(.white).padding(.trailing, 4)
                    } else {
                        Image(systemName: "keyboard.badge.eye")
                    }
                    Text(generatingPDF == pdfKind ? "Generating\u{2026}" : pdfLabel)
                }
                .frame(maxWidth: .infinity).padding()
                .background(Color.purple)
                .foregroundColor(.white).cornerRadius(10)
            }
            .disabled(generatingPDF != nil)
        }
    }

    // MARK: - Export Actions

    private func exportPDF(_ kind: PDFKind) {
        guard let session = sessionManager.currentSession else { return }
        generatingPDF = kind
        let mode: KeyboardViewPDFExporter.Mode = kind == .cleaned ? .cleaned : .raw
        Task.detached(priority: .userInitiated) {
            let exporter = KeyboardViewPDFExporter()
            let url = await exporter.exportPDF(
                events: sessionManager.allEvents,
                session: session,
                participant: sessionManager.participant,
                mode: mode
            )
            await MainActor.run {
                generatingPDF = nil
                if let url { shareItem = ShareItem(url: url) }
            }
        }
    }

    private func exportGaussianPDF() {
        guard let session = sessionManager.currentSession else { return }
        generatingPDF = .gaussian
        Task.detached(priority: .userInitiated) {
            let events = GaussianModelStore.shared.loadEvents()
            let exporter = GaussianKeyboardExporter()
            let url = await exporter.exportPDF(
                events: events,
                session: session,
                participant: sessionManager.participant
            )
            await MainActor.run {
                generatingPDF = nil
                if let url { shareItem = ShareItem(url: url) }
            }
        }
    }

    private func exportCSV(cleaned: Bool) {
        guard let session = sessionManager.currentSession else { return }
        let exporter = DataExporter()
        let url = cleaned
            ? exporter.exportCleanedKeystrokesCSV(
                session: session,
                events: sessionManager.allEvents,
                participant: sessionManager.participant)
            : exporter.exportKeystrokesCSV(
                session: session,
                events: sessionManager.allEvents,
                participant: sessionManager.participant)
        if let url { shareItem = ShareItem(url: url) }
    }

    @MainActor
    private func loadGroundTruthAnalysisIfNeeded() async {
        guard groundTruthAnalysis == nil, !isLoadingGroundTruth else { return }

        let classicInsertCount = sessionManager.allEvents.reduce(into: 0) { count, event in
            if event.sessionMode == "classic", event.eventType == .insert {
                count += 1
            }
        }
        guard classicInsertCount > 0 else {
            groundTruthError = "No classic insert events are available yet."
            return
        }

        isLoadingGroundTruth = true
        groundTruthError = nil
        let events = sessionManager.allEvents

        do {
            let analysis = try await Task.detached(priority: .userInitiated) {
                try GroundTruthLossAnalyzer.analyze(events: events)
            }.value
            groundTruthAnalysis = analysis
        } catch {
            groundTruthError = error.localizedDescription
        }

        isLoadingGroundTruth = false
    }
}

// MARK: - BetweenSessionView

struct BetweenSessionView: View {
    var sessionManager: SessionManager

    private var completedCount: Int { sessionManager.completedStudySessions }
    private var totalCount: Int { sessionManager.totalStudySessions }
    private var isClassicOnly: Bool { sessionManager.studyDesign == .classicOnly }
    private var switchingToAdaptive: Bool { !isClassicOnly && completedCount == totalCount / 2 }
    private var nextMode: SessionMode { sessionManager.currentSessionMode }

    var body: some View {
        VStack(spacing: 24) {
            // Buttons at top so they're out of thumb-reach from the keyboard area
            VStack(spacing: 12) {
                Button(action: { sessionManager.continueToNextSession() }) {
                    Text("Continue to Session \(completedCount + 1)")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(nextMode == .gaussian ? Color.teal : Color.orange)
                        .cornerRadius(14)
                }
                .padding(.horizontal, 32)

                Button(action: { sessionManager.endStudyEarly() }) {
                    Text("End Study & Export Data")
                        .fontWeight(.semibold)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(14)
                }
                .padding(.horizontal, 32)
            }
            .padding(.top, 16)

            Divider()

            // Session progress
            VStack(spacing: 8) {
                Text("Session \(completedCount) of \(totalCount) Complete")
                    .font(.title2).fontWeight(.bold)

                // Progress dots
                HStack(spacing: 8) {
                    ForEach(0..<totalCount, id: \.self) { i in
                        let isClassic = isClassicOnly || i < totalCount / 2
                        let isDone = i < completedCount
                        Circle()
                            .fill(isDone
                                  ? (isClassic ? Color.orange : Color.teal)
                                  : Color(.systemGray4))
                            .frame(width: 12, height: 12)
                    }
                }
            }

            // Session stats
            if let session = sessionManager.currentSession {
                let meanWPM = sessionManager.completedTrials.isEmpty ? 0.0
                    : sessionManager.completedTrials.map(\.wpm).reduce(0, +)
                      / Double(sessionManager.completedTrials.count)

                HStack(spacing: 24) {
                    statPill(title: "Mean WPM",
                             value: String(format: "%.0f", meanWPM),
                             color: .orange)
                    statPill(title: "Accuracy",
                             value: String(format: "%.1f%%", session.meanAccuracy * 100),
                             color: .green)
                    statPill(title: "Backspaces",
                             value: "\(session.totalBackspaces)",
                             color: .secondary)
                }
            }

            // Mode transition notice
            if switchingToAdaptive {
                VStack(spacing: 6) {
                    Text("Switching to Adaptive Keyboard")
                        .font(.headline)
                        .foregroundColor(.teal)
                    Text("The Gaussian model trained on your classic sessions will now guide tap classification.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.teal.opacity(0.1)))
                .padding(.horizontal)
            } else {
                let modeLabel = nextMode == .gaussian ? "Adaptive (Gaussian)" : "Classic"
                let label = isClassicOnly
                    ? "Next: Session \(completedCount + 1)"
                    : "Next: Session \(completedCount + 1) · \(modeLabel)"
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private func statPill(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3).fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 72)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
    }
}

// MARK: - Helpers

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - KeyboardViewPDFExporter
//
// Exports the same keyboard-layout dot plot shown on screen, with:
//   - Participant/date header
//   - Keyboard key outlines
//   - Normalized coordinate axes grid (0.00–1.00)
//   - Colored dots at per-key normalized tap positions
//   - Legend

final class KeyboardViewPDFExporter {

    enum Mode {
        case raw       // include all taps
        case cleaned   // drop taps flagged as spatial or far_from_target
    }

    private let pageW:  CGFloat = 612
    private let pageH:  CGFloat = 792
    private let margin: CGFloat = 36

    private let allKeys = ["q","w","e","r","t","y","u","i","o","p",
                           "a","s","d","f","g","h","j","k","l",
                           "z","x","c","v","b","n","m","space","delete"]

    // Layout constants (mirrors TapDotPlotView)
    private let row0 = ["q","w","e","r","t","y","u","i","o","p"]
    private let row1 = ["a","s","d","f","g","h","j","k","l"]
    private let row2 = ["z","x","c","v","b","n","m"]

    private let sidePad: CGFloat = 3
    private let keyGap:  CGFloat = 6
    private let rowGap:  CGFloat = 13
    private let topPad:  CGFloat = 11

    func exportPDF(
        events: [InputEventData],
        session: Session,
        participant: Participant?,
        mode: Mode = .raw
    ) async -> URL? {

        let validKeys = Set(row0 + row1 + row2 + ["space", "delete"])
        let validEvents = events.filter { e in
            guard !e.keyLabel.isEmpty,
                  validKeys.contains(e.keyLabel),
                  e.keyWidth > 0
            else { return false }
            guard mode == .cleaned else { return true }
            let flags = KeystrokeCleaner.flag(e).flags
            return !flags.contains(.spatial) && !flags.contains(.farFromTarget)
        }
        guard !validEvents.isEmpty else { return nil }

        let first = participant?.firstName ?? "unknown"
        let last  = participant?.lastName  ?? "unknown"
        let suffix = mode == .cleaned ? "_cleaned" : ""
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("keyboard_view\(suffix)_\(first)_\(last).pdf")

        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pageW, height: pageH)
        )

        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let headerBottom = drawHeader(ctx: ctx, session: session,
                                          participant: participant,
                                          tapCount: validEvents.count, mode: mode)
            let cgCtx = ctx.cgContext

            // Canvas area
            let canvasLeft   = margin + sidePad
            let canvasRight  = pageW - margin - sidePad
            let canvasTop    = headerBottom + 16
            let canvasW      = canvasRight - canvasLeft

            let kw   = (canvasW - 2 * sidePad - 9 * keyGap) / 10
            let sp   = (canvasW - 2 * sidePad - 7 * kw - 8 * keyGap) / 2
            let keyH = (kw * 1.35).rounded()
            let canvasH = topPad + 4 * keyH + 3 * rowGap + 8

            let frames = buildFrames(ox: canvasLeft, plotTop: canvasTop,
                                     kw: kw, sp: sp, keyH: keyH, plotW: canvasW)

            // ── Background (dark mode) ─────────────────────────────────────────
            cgCtx.setFillColor(UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor)
            cgCtx.fill(CGRect(x: canvasLeft, y: canvasTop, width: canvasW, height: canvasH))

            // ── Normalized grid (0.00 → 1.00) ──────────────────────────────────
            let gridSteps: [CGFloat] = [0, 0.25, 0.5, 0.75, 1.0]
            cgCtx.setStrokeColor(UIColor.white.withAlphaComponent(0.08).cgColor)
            cgCtx.setLineWidth(0.4)

            for t in gridSteps {
                // Vertical
                let gx = canvasLeft + t * canvasW
                cgCtx.move(to: CGPoint(x: gx, y: canvasTop))
                cgCtx.addLine(to: CGPoint(x: gx, y: canvasTop + canvasH))
                // Horizontal
                let gy = canvasTop + t * canvasH
                cgCtx.move(to: CGPoint(x: canvasLeft, y: gy))
                cgCtx.addLine(to: CGPoint(x: canvasLeft + canvasW, y: gy))
            }
            cgCtx.strokePath()

            // Grid labels — X axis (below canvas)
            let axisFont = UIFont.monospacedSystemFont(ofSize: 6.5, weight: .regular)
            for t in gridSteps {
                let label = String(format: "%.2f", t)
                drawText(label,
                         at: CGPoint(x: canvasLeft + t * canvasW - 10, y: canvasTop + canvasH + 3),
                         font: axisFont, color: .secondaryLabel, width: 24)
            }
            // Grid labels — Y axis (left of canvas)
            for t in gridSteps {
                let label = String(format: "%.2f", t)
                drawText(label,
                         at: CGPoint(x: canvasLeft - 28, y: canvasTop + t * canvasH - 5),
                         font: axisFont, color: .secondaryLabel, width: 26)
            }

            // Canvas border
            cgCtx.setStrokeColor(UIColor(white: 1, alpha: 0.20).cgColor)
            cgCtx.setLineWidth(0.6)
            cgCtx.stroke(CGRect(x: canvasLeft, y: canvasTop, width: canvasW, height: canvasH))

            // ── Key outlines (dark mode) ─────────────────────────────────────
            for (key, rect) in frames {
                let isSpecial = key.count > 1
                let keyPath = UIBezierPath(roundedRect: rect, cornerRadius: 5)

                let fill: UIColor = isSpecial
                    ? UIColor(white: 0.18, alpha: 1)
                    : UIColor(white: 0.26, alpha: 1)
                cgCtx.setFillColor(fill.cgColor)
                cgCtx.addPath(keyPath.cgPath); cgCtx.fillPath()

                cgCtx.setStrokeColor(UIColor(white: 1, alpha: 0.12).cgColor)
                cgCtx.setLineWidth(0.5)
                cgCtx.addPath(keyPath.cgPath); cgCtx.strokePath()

                // Highlight top edge of key
                cgCtx.setStrokeColor(UIColor(white: 1, alpha: 0.20).cgColor)
                cgCtx.setLineWidth(0.7)
                cgCtx.move(to: CGPoint(x: rect.minX + 3, y: rect.minY + 0.5))
                cgCtx.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.minY + 0.5))
                cgCtx.strokePath()

                // Key label — bottom-left corner so dots don't obscure it
                let display = key == "delete" ? "\u{232B}" : key == "space" ? "\u{23B5}" : key
                let fontSize: CGFloat = key.count > 1 ? 6 : max(5, keyH * 0.22)
                drawText(display,
                         at: CGPoint(x: rect.minX + 2, y: rect.maxY - fontSize - 3),
                         font: .systemFont(ofSize: fontSize, weight: .medium),
                         color: UIColor(white: 1, alpha: 0.70))
            }

            // ── Tap dots (per-key color, white halo, intended char centered in dot)
            let dotR: CGFloat = 4.5
            for e in validEvents {
                guard let frame = frames[e.keyLabel] else { continue }
                let normX = e.keyWidth  > 0 ? e.tapLocalX / e.keyWidth  : 0.5
                let normY = e.keyHeight > 0 ? e.tapLocalY / e.keyHeight : 0.5
                let px = frame.minX + CGFloat(normX) * frame.width
                let py = frame.minY + CGFloat(normY) * frame.height

                let colorKey = e.expectedChar.isEmpty ? e.keyLabel : e.expectedChar

                // White halo for contrast
                cgCtx.setFillColor(UIColor.white.withAlphaComponent(0.80).cgColor)
                cgCtx.fillEllipse(in: CGRect(x: px - dotR - 1, y: py - dotR - 1,
                                              width: (dotR+1)*2, height: (dotR+1)*2))

                cgCtx.setFillColor(keyUIColor(colorKey).withAlphaComponent(0.95).cgColor)
                cgCtx.fillEllipse(in: CGRect(x: px - dotR, y: py - dotR,
                                              width: dotR * 2, height: dotR * 2))

                // Intended key label centered inside dot in white
                let label = colorKey == "space" ? "\u{00B7}" : colorKey == "delete" ? "\u{232B}" : colorKey
                if label.count == 1 {
                    drawTextCentered(label,
                                     in: CGRect(x: px - dotR, y: py - dotR * 0.9,
                                                width: dotR * 2, height: dotR * 2),
                                     font: .monospacedSystemFont(ofSize: dotR * 1.1, weight: .bold),
                                     color: .white)
                }
            }

            // ── Legend (per-key colors) ─────────────────────────────────────────
            let legendY = canvasTop + canvasH + 18
            let shownKeys = Array(Set(validEvents.map {
                $0.expectedChar.isEmpty ? $0.keyLabel : $0.expectedChar
            })).sorted()
            var lx = canvasLeft
            for k in shownKeys {
                cgCtx.setFillColor(keyUIColor(k).cgColor)
                cgCtx.fillEllipse(in: CGRect(x: lx, y: legendY + 1, width: 7, height: 7))
                let display = k == "delete" ? "del" : k == "space" ? "sp" : k
                drawText(display,
                         at: CGPoint(x: lx + 9, y: legendY - 1),
                         font: .monospacedSystemFont(ofSize: 7, weight: .medium),
                         color: .secondaryLabel, width: 22)
                lx += 24
                if lx + 24 > canvasRight { break }
            }
        }

        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Header

    @discardableResult
    private func drawHeader(ctx: UIGraphicsPDFRendererContext, session: Session,
                            participant: Participant?, tapCount: Int,
                            mode: Mode) -> CGFloat {
        let cgCtx = ctx.cgContext
        cgCtx.setFillColor(UIColor.systemPurple.withAlphaComponent(0.85).cgColor)
        cgCtx.fill(CGRect(x: 0, y: 0, width: pageW, height: 40))

        let title = mode == .cleaned
            ? "Tap Distribution \u{2014} Keyboard View (Cleaned)"
            : "Tap Distribution \u{2014} Keyboard View"
        drawText(title,
                 at: CGPoint(x: margin, y: 10),
                 font: .systemFont(ofSize: 14, weight: .bold), color: .white)
        drawText("\(tapCount) taps",
                 at: CGPoint(x: pageW - margin - 60, y: 12),
                 font: .monospacedSystemFont(ofSize: 11, weight: .medium), color: .white, width: 60)

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
        let name = participant.map { "\($0.firstName) \($0.lastName)".trimmingCharacters(in: .whitespaces) } ?? "\u{2014}"
        drawText("Participant: \(name)   Date: \(iso.string(from: session.startedAt))",
                 at: CGPoint(x: margin, y: 44),
                 font: .systemFont(ofSize: 8), color: .secondaryLabel)
        return 56
    }

    // MARK: - Key Frames

    private func buildFrames(ox: CGFloat, plotTop: CGFloat, kw: CGFloat,
                             sp: CGFloat, keyH: CGFloat, plotW: CGFloat) -> [String: CGRect] {
        var f = [String: CGRect]()
        let y0 = plotTop + topPad
        for (i, k) in row0.enumerated() {
            f[k] = CGRect(x: ox + sidePad + CGFloat(i) * (kw + keyGap), y: y0, width: kw, height: keyH)
        }
        let y1 = y0 + keyH + rowGap
        let row1Start = ox + (plotW - 9 * kw - 8 * keyGap) / 2
        for (i, k) in row1.enumerated() {
            f[k] = CGRect(x: row1Start + CGFloat(i) * (kw + keyGap), y: y1, width: kw, height: keyH)
        }
        let y2 = y1 + keyH + rowGap
        let row2Start = ox + sidePad + sp + keyGap
        for (i, k) in row2.enumerated() {
            f[k] = CGRect(x: row2Start + CGFloat(i) * (kw + keyGap), y: y2, width: kw, height: keyH)
        }
        f["delete"] = CGRect(x: ox + plotW - sidePad - sp, y: y2, width: sp, height: keyH)
        let y3 = y2 + keyH + rowGap
        f["space"] = CGRect(x: ox + sidePad + sp + keyGap, y: y3,
                            width: plotW - 2 * sidePad - 2 * sp - 2 * keyGap, height: keyH)
        return f
    }

    // MARK: - Helpers

    private func keyUIColor(_ key: String) -> UIColor {
        let idx = Double(allKeys.firstIndex(of: key) ?? 0)
        let hue = (idx * 0.618033988749895).truncatingRemainder(dividingBy: 1.0)
        let sat: CGFloat = idx.truncatingRemainder(dividingBy: 2) == 0 ? 0.82 : 0.65
        return UIColor(hue: CGFloat(hue), saturation: sat, brightness: 0.88, alpha: 1.0)
    }

    private func drawText(_ text: String, at point: CGPoint,
                          font: UIFont, color: UIColor, width: CGFloat = 200) {
        text.draw(in: CGRect(x: point.x, y: point.y, width: width, height: 20),
                  withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawTextCentered(_ text: String, in rect: CGRect,
                                  font: UIFont, color: UIColor) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let textRect = CGRect(x: rect.minX,
                              y: rect.midY - size.height / 2,
                              width: rect.width,
                              height: size.height)
        text.draw(in: textRect, withAttributes: attrs)
    }
}
