import SwiftUI

struct SessionOverlapView: View {
    let events: [InputEventData]

    @State private var visibleSessionCount = 1
    @State private var layoutMode: TapDotPlotView.LayoutMode = .alpha

    private let sidePad: CGFloat = 3
    private let keyGap: CGFloat = 6
    private let rowGap: CGFloat = 11
    private let topPad: CGFloat = 11
    private let bottomPad: CGFloat = 3
    private let keyH: CGFloat = 42

    private let row0 = ["q","w","e","r","t","y","u","i","o","p"]
    private let row1 = ["a","s","d","f","g","h","j","k","l"]
    private let row2 = ["z","x","c","v","b","n","m"]
    private let numRow0 = ["1","2","3","4","5","6","7","8","9","0"]
    private let numRow1 = ["-","/",":",";","(",")","\u{0024}","&","@","\""]
    private let numRow2p = [".",",","?","!","'"]

    private var canvasHeight: CGFloat {
        topPad + 4 * keyH + 3 * rowGap + bottomPad
    }

    private var sessions: [SessionTapGroup] {
        SessionTapGroup.makeGroups(from: events)
    }

    private var visibleSessions: [SessionTapGroup] {
        Array(sessions.prefix(max(1, min(visibleSessionCount, sessions.count))))
    }

    private var latestOverlapText: String {
        guard visibleSessions.count > 1,
              let latest = visibleSessions.last,
              let similarity = SessionOverlapMetric.similarity(
                latest: latest,
                previous: Array(visibleSessions.dropLast())
              )
        else {
            return "Add a second session to compute overlap."
        }

        return String(
            format: "Latest vs previous overlap: %.3f similarity / %.3f loss",
            similarity,
            1.0 - similarity
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls
                overlayCanvas
                legend
                sessionStats
            }
            .padding()
        }
        .navigationTitle("Session Overlap")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            visibleSessionCount = min(max(1, visibleSessionCount), max(1, sessions.count))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cumulative Overlay")
                        .font(.headline)
                    Text(latestOverlapText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Picker("Layout", selection: $layoutMode) {
                    ForEach(TapDotPlotView.LayoutMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            HStack(spacing: 10) {
                Button(action: addNextSession) {
                    Label(nextButtonTitle, systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sessions.isEmpty)

                Button(action: resetOverlay) {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 44)
                }
                .buttonStyle(.bordered)
                .disabled(sessions.count <= 1)
            }

            Text("Showing \(visibleSessions.count) of \(sessions.count) sessions")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
    }

    private var nextButtonTitle: String {
        guard !sessions.isEmpty else { return "No Sessions" }
        if visibleSessionCount >= sessions.count {
            return "Restart Overlay"
        }
        return "Add Session \(sessions[visibleSessionCount].displayIndex)"
    }

    private var overlayCanvas: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let keyWidth = (width - 2 * sidePad - 9 * keyGap) / 10
            let specialWidth = (width - 2 * sidePad - 7 * keyWidth - 8 * keyGap) / 2
            let frames = buildFrames(width: width, keyWidth: keyWidth, specialWidth: specialWidth)
            let allowedKeys = layoutMode == .alpha ? alphaKeys : numericKeys

            Canvas { context, _ in
                for (_, rect) in frames {
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 5),
                        with: .color(Color(.systemGray5))
                    )
                }

                for (label, rect) in frames {
                    context.stroke(
                        Path(roundedRect: rect, cornerRadius: 5),
                        with: .color(Color(.separator).opacity(0.45)),
                        lineWidth: 0.6
                    )
                    context.draw(
                        Text(keyDisplay(label))
                            .font(.system(size: label.count > 1 ? 7 : 9, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(.secondaryLabel)),
                        at: CGPoint(x: rect.minX + 6, y: rect.maxY - 8)
                    )
                }

                for (sessionOffset, session) in visibleSessions.enumerated() {
                    let color = sessionColor(sessionOffset)
                    for tap in session.taps where allowedKeys.contains(tap.keyLabel) {
                        guard let frame = frames[tap.keyLabel] else { continue }
                        let point = CGPoint(
                            x: frame.minX + CGFloat(tap.normX) * frame.width,
                            y: frame.minY + CGFloat(tap.normY) * frame.height
                        )
                        let radius = CGFloat(5.5 + Double(sessionOffset) * 0.35)

                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: point.x - radius - 1.5,
                                y: point.y - radius - 1.5,
                                width: (radius + 1.5) * 2,
                                height: (radius + 1.5) * 2
                            )),
                            with: .color(.white.opacity(0.82))
                        )
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: point.x - radius,
                                y: point.y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )),
                            with: .color(color.opacity(0.62))
                        )
                        context.stroke(
                            Path(ellipseIn: CGRect(
                                x: point.x - radius,
                                y: point.y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )),
                            with: .color(color.opacity(0.95)),
                            lineWidth: 1.3
                        )
                    }
                }
            }
        }
        .frame(height: canvasHeight)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(visibleSessions.enumerated()), id: \.element.id) { offset, session in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sessionColor(offset))
                            .frame(width: 10, height: 10)
                        Text("S\(session.displayIndex)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var sessionStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Taps")
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(Array(visibleSessions.enumerated()), id: \.element.id) { offset, session in
                HStack {
                    Circle()
                        .fill(sessionColor(offset))
                        .frame(width: 9, height: 9)
                    Text("Session \(session.displayIndex)")
                    Spacer()
                    Text("\(session.taps.count) clean taps")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
    }

    private var alphaKeys: Set<String> {
        Set(row0 + row1 + row2 + ["space", "delete"])
    }

    private var numericKeys: Set<String> {
        Set(numRow0 + numRow1 + numRow2p + ["space"])
    }

    private func addNextSession() {
        guard !sessions.isEmpty else { return }
        if visibleSessionCount >= sessions.count {
            visibleSessionCount = 1
        } else {
            visibleSessionCount += 1
        }
    }

    private func resetOverlay() {
        visibleSessionCount = 1
    }

    private func sessionColor(_ index: Int) -> Color {
        let colors: [Color] = [
            Color(.systemBlue),
            Color(.systemPink),
            Color(.systemGreen),
            Color(.systemOrange),
            Color(.systemPurple),
            Color(.systemRed),
            Color(.systemTeal),
            Color(.systemIndigo),
        ]
        return colors[index % colors.count]
    }

    private func keyDisplay(_ label: String) -> String {
        switch label {
        case "delete": return "\u{232B}"
        case "space": return "\u{23B5}"
        default: return label
        }
    }

    private func buildFrames(width: CGFloat, keyWidth: CGFloat, specialWidth: CGFloat) -> [String: CGRect] {
        layoutMode == .alpha
            ? buildAlphaFrames(width: width, keyWidth: keyWidth, specialWidth: specialWidth)
            : buildNumericFrames(width: width, keyWidth: keyWidth, specialWidth: specialWidth)
    }

    private func buildAlphaFrames(width: CGFloat, keyWidth: CGFloat, specialWidth: CGFloat) -> [String: CGRect] {
        var frames = [String: CGRect]()
        let y0 = topPad
        for (index, key) in row0.enumerated() {
            frames[key] = CGRect(x: sidePad + CGFloat(index) * (keyWidth + keyGap), y: y0, width: keyWidth, height: keyH)
        }
        let y1 = y0 + keyH + rowGap
        let row1Start = (width - 9 * keyWidth - 8 * keyGap) / 2
        for (index, key) in row1.enumerated() {
            frames[key] = CGRect(x: row1Start + CGFloat(index) * (keyWidth + keyGap), y: y1, width: keyWidth, height: keyH)
        }
        let y2 = y1 + keyH + rowGap
        let row2Start = sidePad + specialWidth + keyGap
        for (index, key) in row2.enumerated() {
            frames[key] = CGRect(x: row2Start + CGFloat(index) * (keyWidth + keyGap), y: y2, width: keyWidth, height: keyH)
        }
        frames["delete"] = CGRect(x: width - sidePad - specialWidth, y: y2, width: specialWidth, height: keyH)
        let y3 = y2 + keyH + rowGap
        frames["space"] = CGRect(
            x: sidePad + specialWidth + keyGap,
            y: y3,
            width: width - 2 * sidePad - 2 * specialWidth - 2 * keyGap,
            height: keyH
        )
        return frames
    }

    private func buildNumericFrames(width: CGFloat, keyWidth: CGFloat, specialWidth: CGFloat) -> [String: CGRect] {
        var frames = [String: CGRect]()
        let y0 = topPad
        for (index, key) in numRow0.enumerated() {
            frames[key] = CGRect(x: sidePad + CGFloat(index) * (keyWidth + keyGap), y: y0, width: keyWidth, height: keyH)
        }
        let y1 = y0 + keyH + rowGap
        for (index, key) in numRow1.enumerated() {
            frames[key] = CGRect(x: sidePad + CGFloat(index) * (keyWidth + keyGap), y: y1, width: keyWidth, height: keyH)
        }
        let y2 = y1 + keyH + rowGap
        let punctuationWidth = (width - 2 * sidePad - 2 * specialWidth - 6 * keyGap) / 5
        let punctuationStart = sidePad + specialWidth + keyGap
        for (index, key) in numRow2p.enumerated() {
            frames[key] = CGRect(x: punctuationStart + CGFloat(index) * (punctuationWidth + keyGap), y: y2, width: punctuationWidth, height: keyH)
        }
        let y3 = y2 + keyH + rowGap
        frames["space"] = CGRect(
            x: sidePad + specialWidth + keyGap,
            y: y3,
            width: width - 2 * sidePad - 2 * specialWidth - 2 * keyGap,
            height: keyH
        )
        return frames
    }
}

private struct SessionTapGroup: Identifiable {
    let studySessionIndex: Int
    let taps: [SessionTap]

    var id: Int { studySessionIndex }
    var displayIndex: Int { studySessionIndex + 1 }

    static func makeGroups(from events: [InputEventData]) -> [SessionTapGroup] {
        let taps = events.compactMap(SessionTap.init(event:))
        let grouped = Dictionary(grouping: taps, by: \.studySessionIndex)
        return grouped.keys.sorted().map { index in
            SessionTapGroup(studySessionIndex: index, taps: grouped[index] ?? [])
        }
    }
}

private struct SessionTap {
    let studySessionIndex: Int
    let keyLabel: String
    let normX: Double
    let normY: Double

    init?(event: InputEventData) {
        guard event.eventType == .insert,
              !event.keyLabel.isEmpty,
              event.keyWidth > 0,
              event.keyHeight > 0
        else {
            return nil
        }

        let flags = KeystrokeCleaner.flag(event)
        guard !flags.isOutlier else { return nil }

        studySessionIndex = event.studySessionIndex
        keyLabel = event.keyLabel
        normX = min(max(event.tapNormX, 0), 1)
        normY = min(max(event.tapNormY, 0), 1)
    }
}

private enum SessionOverlapMetric {
    private struct Cell: Hashable {
        let row: Int
        let col: Int
    }

    static func similarity(latest: SessionTapGroup, previous: [SessionTapGroup], gridSize: Int = 30) -> Double? {
        let previousTaps = previous.flatMap(\.taps)
        guard !latest.taps.isEmpty, !previousTaps.isEmpty else { return nil }

        let labels = Set(latest.taps.map(\.keyLabel)).intersection(previousTaps.map(\.keyLabel))
        var weightedSimilarities: [(Double, Int)] = []

        for label in labels {
            let current = latest.taps.filter { $0.keyLabel == label }
            let prior = previousTaps.filter { $0.keyLabel == label }
            guard current.count >= 3, prior.count >= 3 else { continue }
            guard let similarity = weightedJaccard(
                buildHistogram(current, gridSize: gridSize),
                buildHistogram(prior, gridSize: gridSize)
            ) else {
                continue
            }
            weightedSimilarities.append((similarity, current.count + prior.count))
        }

        guard !weightedSimilarities.isEmpty else { return nil }
        let totalWeight = weightedSimilarities.reduce(0) { $0 + $1.1 }
        return weightedSimilarities.reduce(0.0) { $0 + $1.0 * Double($1.1) } / Double(totalWeight)
    }

    private static func buildHistogram(_ taps: [SessionTap], gridSize: Int) -> [Cell: Int] {
        var histogram: [Cell: Int] = [:]
        for tap in taps {
            let col = min(max(Int(tap.normX * Double(gridSize)), 0), gridSize - 1)
            let row = min(max(Int(tap.normY * Double(gridSize)), 0), gridSize - 1)
            histogram[Cell(row: row, col: col), default: 0] += 1
        }
        return histogram
    }

    private static func weightedJaccard(_ a: [Cell: Int], _ b: [Cell: Int]) -> Double? {
        let totalA = a.values.reduce(0, +)
        let totalB = b.values.reduce(0, +)
        guard totalA > 0, totalB > 0 else { return nil }

        let cells = Set(a.keys).union(b.keys)
        var numerator = 0.0
        var denominator = 0.0
        for cell in cells {
            let pa = Double(a[cell] ?? 0) / Double(totalA)
            let pb = Double(b[cell] ?? 0) / Double(totalB)
            numerator += min(pa, pb)
            denominator += max(pa, pb)
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }
}

struct GaussianBoundarySessionView: View {
    let participant: Participant?
    let session: Session?

    @State private var visibleSessionCount: Int
    @State private var previewImage: UIImage?
    @State private var isRenderingPreview = false
    @State private var shareItem: ShareItem? = nil
    @State private var exportingKind: ExportKind? = nil

    private let snapshots: [GaussianBoundarySessionSnapshot]

    private enum ExportKind {
        case current
        case all
    }

    init(events: [InputEventData], participant: Participant?, session: Session?) {
        let builtSnapshots = GaussianBoundaryTimeline.sessionSnapshots(from: events)
        self.snapshots = builtSnapshots
        self.participant = participant
        self.session = session
        _visibleSessionCount = State(initialValue: builtSnapshots.isEmpty ? 0 : 1)
    }

    private var visibleSnapshot: GaussianBoundarySessionSnapshot? {
        guard !snapshots.isEmpty,
              visibleSessionCount > 0,
              visibleSessionCount <= snapshots.count else {
            return nil
        }
        return snapshots[visibleSessionCount - 1]
    }

    private var headerText: String {
        guard let snapshot = visibleSnapshot else {
            return "No clean session boundary data available."
        }
        return "Session \(snapshot.displayIndex) boundary with \(snapshot.cleanEvents.count) clean events"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls
                previewSection
                sourceSummary
                exportButtons
            }
            .padding()
        }
        .navigationTitle("Gaussian Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Boundary Viewer")
                .font(.headline)
            Text("Each step fits the current session first, then backs off to prior-session data for sparse keys.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button(action: addNextSession) {
                    Label(nextButtonTitle, systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(snapshots.isEmpty)

                Button(action: resetViewer) {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 44)
                }
                .buttonStyle(.bordered)
                .disabled(snapshots.count <= 1)
            }

            Text(headerText)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gaussian Boundary")
                .font(.subheadline)
                .fontWeight(.semibold)

            GeometryReader { geo in
                let width = max(280, geo.size.width)
                let height = max(220, width * 0.46)

                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.systemGray6))

                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(8)
                    } else if snapshots.isEmpty {
                        Text("No boundary snapshots yet.")
                            .foregroundColor(.secondary)
                    }

                    if isRenderingPreview {
                        ProgressView()
                            .padding(12)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .task(id: "\(visibleSessionCount)-\(Int(width.rounded()))") {
                    await renderPreview(width: width, height: height)
                }
            }
            .frame(height: 250)
        }
    }

    private var sourceSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backoff Summary")
                .font(.subheadline)
                .fontWeight(.semibold)

            if let snapshot = visibleSnapshot {
                HStack(spacing: 12) {
                    sourcePill(
                        title: "Current",
                        value: "\(snapshot.fittedCurrentKeys)",
                        color: .green
                    )
                    sourcePill(
                        title: "Prior",
                        value: "\(snapshot.priorModelKeys)",
                        color: .orange
                    )
                    sourcePill(
                        title: "Geometry",
                        value: "\(snapshot.geometryFallbackKeys)",
                        color: .secondary
                    )
                }

                Text("Session \(snapshot.displayIndex) uses \(snapshot.priorEventCount) prior clean events for backoff when a key is too sparse.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("No boundary summaries available.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
    }

    private var exportButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloads")
                .font(.headline)
            Text("PDF works best here because it can package the current page or the full session sequence in one file.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: { exportCurrentSessionPDF() }) {
                HStack {
                    if exportingKind == .current {
                        ProgressView().tint(.white).padding(.trailing, 4)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text(exportingKind == .current ? "Generating…" : "Current Session Boundary PDF")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.teal)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(exportingKind != nil || visibleSnapshot == nil || session == nil)

            Button(action: { exportAllSessionsPDF() }) {
                HStack {
                    if exportingKind == .all {
                        ProgressView().tint(.white).padding(.trailing, 4)
                    } else {
                        Image(systemName: "doc.on.doc")
                    }
                    Text(exportingKind == .all ? "Generating…" : "All Session Boundaries PDF")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.indigo)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(exportingKind != nil || snapshots.isEmpty || session == nil)
        }
    }

    private var nextButtonTitle: String {
        guard !snapshots.isEmpty else { return "No Sessions" }
        if visibleSessionCount >= snapshots.count {
            return "Restart Viewer"
        }
        return "Show Session \(snapshots[visibleSessionCount].displayIndex)"
    }

    private func addNextSession() {
        guard !snapshots.isEmpty else { return }
        if visibleSessionCount >= snapshots.count {
            visibleSessionCount = 1
        } else {
            visibleSessionCount += 1
        }
    }

    private func resetViewer() {
        visibleSessionCount = snapshots.isEmpty ? 0 : 1
    }

    private func sourcePill(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
    }

    @MainActor
    private func renderPreview(width: CGFloat, height: CGFloat) async {
        guard let snapshot = visibleSnapshot, width > 0, height > 0 else {
            previewImage = nil
            return
        }

        isRenderingPreview = true
        let exporter = GaussianKeyboardExporter()
        previewImage = exporter.previewImage(
            snapshot: snapshot,
            size: CGSize(width: width, height: height)
        )
        isRenderingPreview = false
    }

    private func exportCurrentSessionPDF() {
        guard let session, let snapshot = visibleSnapshot else { return }
        exportingKind = .current
        Task {
            let exporter = GaussianKeyboardExporter()
            let url = await exporter.exportSessionPDF(
                snapshots: [snapshot],
                session: session,
                participant: participant,
                visibleSessionCount: snapshot.sessionOrdinal
            )
            await MainActor.run {
                exportingKind = nil
                if let url { shareItem = ShareItem(url: url) }
            }
        }
    }

    private func exportAllSessionsPDF() {
        guard let session else { return }
        exportingKind = .all
        Task {
            let exporter = GaussianKeyboardExporter()
            let url = await exporter.exportSessionPDF(
                snapshots: snapshots,
                session: session,
                participant: participant
            )
            await MainActor.run {
                exportingKind = nil
                if let url { shareItem = ShareItem(url: url) }
            }
        }
    }
}
