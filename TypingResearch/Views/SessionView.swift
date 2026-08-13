import SwiftUI
import SwiftData

struct SessionView: View {
    var sessionManager: SessionManager

    var body: some View {
        Group {
            if sessionManager.isStudyComplete {
                SummaryView(sessionManager: sessionManager)
            } else if sessionManager.isSessionComplete {
                BetweenSessionView(sessionManager: sessionManager)
            } else if sessionManager.isAwaitingSessionStart {
                SessionBriefingView(sessionManager: sessionManager)
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
    @State private var zippingHandData: Bool = false
    @State private var zippingResearchPackage: Bool = false
    @State private var showPostureSelect: Bool = false
    @State private var exportValidationMessage: String? = nil

    private enum PDFKind { case raw, cleaned }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if sessionManager.studyRole == .researcher {
                        if sessionManager.isPostureTrainingRun {
                            postureContinueSection
                            Divider()
                        }
                        ResearcherAnalysisPanel(sessionManager: sessionManager)
                        Divider()
                        exportButtons
                    } else {
                        participantCompleteSection
                    }
                }
                .padding()
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
                Button("New participant", role: .destructive) {
                    HandImageStore.shared.deleteAll()
                    sessionManager.reset()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showPostureSelect) {
                PostureSelectView(
                    onSelect: { posture in
                        showPostureSelect = false
                        sessionManager.startNextPostureRun(posture: posture)
                    },
                    onCancel: { showPostureSelect = false }
                )
            }
        }
    }

    private var participantCompleteSection: some View {
        VStack(spacing: 16) {
            Text("Thanks for completing this phase.")
                .font(.title2)
                .fontWeight(.bold)
            HStack(spacing: 24) {
                miniStat(label: "WPM", value: String(format: "%.1f", mean(sessionManager.studySessionSummaries.map(\.meanWPM))))
                miniStat(label: "Accuracy", value: String(format: "%.1f%%", mean(sessionManager.studySessionSummaries.map(\.meanAccuracy)) * 100))
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemGray6)))
    }

    // MARK: - Posture Training Run — collect next posture
    //
    // Shown only after a posture training run: lets the participant loop back
    // and collect the remaining postures (L / R / Mid) without resetting.
    // pendingHandSamples accumulates across runs, so the Hand Data Zip below
    // exports every posture's frames + IMU in ONE zip.

    private var postureFrameCounts: [(HoldingHand, Int)] {
        let samples = sessionManager.pendingHandSamples
        return [HoldingHand.left, .right, .both].map { hand in
            (hand, samples.filter { $0.holdingHand == hand }.count)
        }
    }

    private var postureContinueSection: some View {
        VStack(spacing: 12) {
            Text("Posture Training Data")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                ForEach(postureFrameCounts, id: \.0) { hand, count in
                    VStack(spacing: 2) {
                        Text("\(count)")
                            .font(.title3).fontWeight(.semibold)
                            .foregroundColor(count > 0 ? .primary : .secondary)
                        Text(hand == .both ? "Mid" : hand.displayName)
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
                }
            }

            Button(action: { showPostureSelect = true }) {
                Label("Collect Another Posture", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.blue)
                    .foregroundColor(.white).cornerRadius(10)
            }

            Text("Frames from every run stay together — export them all in one Hand Data Zip below once each posture is collected.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mean(_ vals: [Double]) -> Double {
        vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline).fontWeight(.semibold)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(minWidth: 48)
    }


    // MARK: - Export Buttons

    private var exportButtons: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Research package")
                    .font(.headline)
                Text("Manual share bundle for Drive: raw + cleaned + behavior annotations + LM edited/unedited traces + touch gestures + hand/IMU files.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: exportResearchPackage) {
                    HStack {
                        if zippingResearchPackage {
                            ProgressView().padding(.trailing, 4)
                            Text("Packaging…")
                        } else {
                            Image(systemName: "tray.and.arrow.up")
                            Text("Research Package Zip (Share to Drive)")
                        }
                    }
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.blue)
                    .foregroundColor(.white).cornerRadius(10)
                }
                .disabled(zippingResearchPackage)
                if let exportValidationMessage {
                    Text(exportValidationMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

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

            VStack(alignment: .leading, spacing: 8) {
                Text("Hand data")
                    .font(.headline)
                Text("Holding-hand manifest CSV + captured images (HandyTrak-style).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: exportHandData) {
                    HStack {
                        if zippingHandData {
                            ProgressView().padding(.trailing, 4)
                            Text("Zipping\u{2026}")
                        } else {
                            Image(systemName: "hand.raised")
                            Text("Hand Data Zip (CSV + Images)")
                        }
                    }
                    .frame(maxWidth: .infinity).padding()
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary).cornerRadius(10)
                }
                .disabled(zippingHandData)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: item.urls)
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
        let events = sessionManager.allEvents
        let participant = sessionManager.participant
        Task.detached(priority: .userInitiated) {
            let exporter = KeyboardViewPDFExporter()
            let url = await exporter.exportPDF(
                events: events,
                session: session,
                participant: participant,
                mode: mode
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

    private func exportHandData() {
        let samples = sessionManager.pendingHandSamples
        guard !samples.isEmpty, !zippingHandData else { return }
        let participant = sessionManager.participant
        zippingHandData = true
        Task.detached(priority: .userInitiated) {
            let exporter = DataExporter()
            let url = exporter.exportHandDataZip(samples: samples, participant: participant)
            await MainActor.run {
                zippingHandData = false
                if let url { shareItem = ShareItem(url: url) }
            }
        }
    }

    private func exportResearchPackage() {
        guard let session = sessionManager.currentSession else { return }
        guard !zippingResearchPackage else { return }
        zippingResearchPackage = true
        exportValidationMessage = nil
        let events = sessionManager.allEvents
        let participant = sessionManager.participant
        let handSamples = sessionManager.pendingHandSamples
        Task.detached(priority: .userInitiated) {
            let exporter = DataExporter()
            let result = exporter.exportResearchPackageZipWithValidation(
                session: session,
                events: events,
                participant: participant,
                handSamples: handSamples
            )
            await MainActor.run {
                zippingResearchPackage = false
                if result.report.isComplete {
                    exportValidationMessage = "Artifact validation passed."
                } else {
                    exportValidationMessage = "Missing artifacts: \(result.report.missingArtifacts.joined(separator: ", "))"
                }
                if let url = result.url { shareItem = ShareItem(url: url) }
            }
        }
    }

}

// MARK: - BetweenSessionView

struct BetweenSessionView: View {
    var sessionManager: SessionManager

    private var isClassicOnly: Bool { sessionManager.studyDesign == .classicOnly }
    private var switchingToAdaptive: Bool { sessionManager.isAwaitingPhaseBAnalysis }
    private var nextMode: SessionMode { sessionManager.currentSessionMode }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if sessionManager.studyRole == .researcher {
                    researcherActions
                } else {
                    participantContinue
                }

                Divider()

                VStack(spacing: 8) {
                    let phaseDone = max(0, sessionManager.currentPhaseSessionNumber - 1)
                    let phaseTotal = max(1, sessionManager.currentPhaseTotalSessions)
                    Text("\(sessionManager.currentStudyPhase.rawValue): Session \(phaseDone) of \(phaseTotal) Complete")
                        .font(.title2).fontWeight(.bold)
                }

                if let session = sessionManager.currentSession {
                    let meanWPM = sessionManager.completedTrials.isEmpty ? 0.0
                        : sessionManager.completedTrials.map(\.wpm).reduce(0, +)
                          / Double(sessionManager.completedTrials.count)

                    HStack(spacing: 24) {
                        statPill(title: "WPM",
                                 value: String(format: "%.0f", meanWPM),
                                 color: .orange)
                        statPill(title: "Accuracy",
                                 value: String(format: "%.1f%%", session.meanAccuracy * 100),
                                 color: .green)
                    }
                }

                if sessionManager.studyRole == .researcher {
                    researcherExtras
                    Divider()
                    ResearcherAnalysisPanel(sessionManager: sessionManager)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
    }

    private var participantContinue: some View {
        Button(action: { sessionManager.continueToNextSession() }) {
            Text("Continue to Session \(sessionManager.currentPhaseSessionNumber) of \(sessionManager.currentPhaseTotalSessions)")
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(nextMode == .gaussian ? Color.teal : Color.orange)
                .cornerRadius(14)
        }
        .padding(.horizontal, 32)
    }

    private var researcherActions: some View {
        VStack(spacing: 12) {
            if sessionManager.isAwaitingPhaseBAnalysis {
                Button(action: { sessionManager.runPhaseAAnalysisAndPreparePhaseB() }) {
                    HStack {
                        if sessionManager.isAnalyzingPhaseTransition {
                            ProgressView().padding(.trailing, 6)
                        }
                        Text("Analyze Phase A & Prepare Phase B")
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.indigo)
                    .cornerRadius(14)
                }
                .disabled(sessionManager.isAnalyzingPhaseTransition)
                .padding(.horizontal, 32)
            } else {
                participantContinue
            }

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
    }

    @ViewBuilder
    private var researcherExtras: some View {
        if switchingToAdaptive {
            VStack(spacing: 6) {
                Text("Analyzing your data")
                    .font(.headline)
                    .foregroundColor(.indigo)
                Text("We build a frozen Phase B Gaussian snapshot from your Phase A sessions, then continue with adaptive sessions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.indigo.opacity(0.1)))
            .padding(.horizontal)
        } else {
            let modeLabel = nextMode == .gaussian ? "Adaptive (Gaussian)" : "Classic"
            let postureLabel = sessionManager.currentAssignedPosture.displayName
            let phaseNum = sessionManager.currentPhaseSessionNumber
            let phaseTotal = sessionManager.currentPhaseTotalSessions
            let label = isClassicOnly
                ? "Next: Session \(phaseNum) of \(phaseTotal) · \(postureLabel)"
                : "Next: \(sessionManager.currentStudyPhase.rawValue) · Session \(phaseNum) of \(phaseTotal) · \(modeLabel) · \(postureLabel)"
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
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

// MARK: - SessionBriefingView

struct SessionBriefingView: View {
    var sessionManager: SessionManager
    @State private var step: BriefingStep = .intro
    @State private var selectedTopic: StudyTopic?
    @State private var showTopicError = false

    private enum BriefingStep {
        case intro
        case topic
    }

    private var holdInstruction: String {
        switch sessionManager.currentAssignedPosture {
        case .left:
            return "Please hold the phone using your left hand, and type with your left hand."
        case .right:
            return "Please hold the phone using your right hand, and type with your right hand."
        case .both:
            return "Please hold the phone using both hands, and type with both thumbs."
        case .unknown:
            return "Please hold the phone naturally and type as you usually would."
        }
    }

    private var phaseName: String {
        sessionManager.currentStudyPhase == .phaseB ? "Phase 2" : "Phase 1"
    }

    private var sessionNumber: Int {
        sessionManager.currentPhaseSessionNumber
    }

    var body: some View {
        VStack(spacing: 0) {
            if step == .intro {
                introStep
            } else {
                topicStep
            }
        }
        .background(Color.black.ignoresSafeArea())
        .alert("Choose a topic", isPresented: $showTopicError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Select a topic from the list, then tap Start session \(sessionNumber).")
        }
    }

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(phaseName)")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
            Text("You are required to write for one minute per session on a topic that you will choose from the list on the next screen.")
                .foregroundColor(.white.opacity(0.92))
            Text("This is Session \(sessionNumber) of \(sessionManager.currentPhaseTotalSessions).")
                .foregroundColor(.white.opacity(0.8))
            Text(holdInstruction)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            Text("The front camera will stay on while you type, so we can record how you hold the phone.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))

            Spacer(minLength: 8)

            Button {
                step = .topic
            } label: {
                Text("Next")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(20)
    }

    private var topicStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session \(sessionNumber) of \(sessionManager.currentPhaseTotalSessions)")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text("Choose a topic to write about for one minute.")
                .foregroundColor(.white.opacity(0.85))
            Text(holdInstruction)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(StudyTopic.allCases) { topic in
                        Button {
                            selectedTopic = topic
                        } label: {
                            HStack(alignment: .top) {
                                Text(topic.rawValue)
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                if selectedTopic == topic {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(selectedTopic == topic
                                          ? Color.blue.opacity(0.45)
                                          : Color.white.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 8)
            }

            Button {
                guard let selectedTopic else {
                    showTopicError = true
                    return
                }
                sessionManager.setNextSessionTopic(selectedTopic)
                sessionManager.beginPreparedSession()
            } label: {
                Text("Start session \(sessionNumber)")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(20)
    }
}

// MARK: - Helpers

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]

    /// Convenience init for sharing a single URL (backward-compatible).
    init(url: URL) { self.urls = [url] }

    /// Init for sharing multiple URLs (hand manifest + images).
    init(urls: [URL]) { self.urls = urls }
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
