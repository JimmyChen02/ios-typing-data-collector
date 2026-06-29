import Foundation
import SwiftData
import Observation
import CoreGraphics

// MARK: - SessionMode

enum SessionMode: Sendable {
    case classic   // fixed rectangular hit regions (standard keyboard)
    case gaussian  // per-key Gaussian + Mahalanobis hit classification
}

// MARK: - StudyDesign

enum StudyDesign: Sendable {
    case classicAndAdaptive  // first half classic, second half gaussian
    case classicOnly         // all sessions use the classic keyboard
}

// MARK: - TapInfo

struct TapInfo: Sendable {
    let keyLabel: String
    let tapLocalX: Double   // tap x within key, in points from key left edge
    let tapLocalY: Double   // tap y within key, in points from key top edge
    let keyWidth: Double
    let keyHeight: Double

    static let none = TapInfo(keyLabel: "", tapLocalX: 0, tapLocalY: 0, keyWidth: 0, keyHeight: 0)
}

// MARK: - InputEventData (transient, not SwiftData)

struct InputEventData: Sendable {
    let trialId: UUID
    let sessionId: UUID
    let studyId: UUID
    let timestamp: Date
    let eventType: InputEventType
    let replacementString: String
    let rangeStart: Int
    let rangeLength: Int
    let expectedIndex: Int
    let keyLabel: String
    let tapLocalX: Double     // tap x within key, in points from key left edge
    let tapLocalY: Double     // tap y within key, in points from key top edge
    let keyWidth: Double
    let keyHeight: Double
    let keyRow: String        // "top" | "middle" | "bottom" | "space"
    let keyCol: Int?          // column index; nil for space/delete/return
    let expectedChar: String
    let actualChar: String
    let correctedChar: String // delete event: last char of textBefore; else ""
    let isCorrect: Bool
    let previousKeyLabel: String
    let textBefore: String
    let textAfter: String     // kept for liveTypedText tracking
    let interKeyIntervalMs: Double
    let sessionMode: String        // "classic" or "gaussian"
    let studySessionIndex: Int     // 0-based index within the study
    let trialIndex: Int            // 0-based trial index within the session

    // Computed for legacy exporter compatibility (not exported to CSV)
    var tapNormX: Double { keyWidth  > 0 ? tapLocalX / keyWidth  : 0.5 }
    var tapNormY: Double { keyHeight > 0 ? tapLocalY / keyHeight : 0.5 }
    var keyScreenX: Double { 0 }
    var keyScreenY: Double { 0 }
}

struct RawInputEvent: Sendable {
    let timestamp: Date
    let eventType: InputEventType
    let replacementString: String
    let rangeStart: Int
    let rangeLength: Int
    let textBefore: String
    let textAfter: String
    let tapInfo: TapInfo
}

// MARK: - StudySessionSummary

struct StudySessionSummary {
    let sessionIndex: Int   // 0-based
    let mode: String        // "classic" or "gaussian"
    let meanAccuracy: Double
    let meanWPM: Double
    let totalBackspaces: Int
    // Cleaning stats (insert events only — deletes excluded from rate)
    let totalInserts: Int
    let flagCounts: [String: Int]   // OutlierFlag.rawValue → count of INSERT events carrying that flag
    var flaggedInserts: Int { flagCounts.values.reduce(0, +) }
    var uniqueFlaggedInserts: Int   // events with at least one flag
}

private extension RawInputEvent {
    func materialized(
        trial: Trial?,
        session: Session?,
        studyId: UUID,
        sessionMode: SessionMode,
        studySessionIndex: Int,
        previousKeyLabel: inout String,
        previousTimestamp: inout Date?
    ) -> InputEventData {
        guard let trial, let session else {
            fatalError("No active trial/session")
        }

        let iki: Double
        if let last = previousTimestamp {
            iki = timestamp.timeIntervalSince(last) * 1000.0
        } else {
            iki = 0.0
        }
        previousTimestamp = timestamp

        let targetChars = Array(trial.targetText)
        let expectedIndex = rangeStart

        let expectedChar: String
        if eventType == .delete {
            expectedChar = ""
        } else if expectedIndex >= 0 && expectedIndex < targetChars.count {
            expectedChar = String(targetChars[expectedIndex])
        } else {
            expectedChar = ""
        }

        let actualChar: String
        if eventType == .insert || eventType == .replace {
            actualChar = replacementString.isEmpty ? "" : String(replacementString.prefix(1))
        } else {
            actualChar = ""
        }

        let isCorrect = eventType != .delete && !actualChar.isEmpty && actualChar == expectedChar

        let correctedChar: String
        if eventType == .delete && !textBefore.isEmpty {
            correctedChar = String(textBefore.last!)
        } else {
            correctedChar = ""
        }

        let prevKey = previousKeyLabel
        if !tapInfo.keyLabel.isEmpty {
            previousKeyLabel = tapInfo.keyLabel
        }

        return InputEventData(
            trialId: trial.id,
            sessionId: session.id,
            studyId: studyId,
            timestamp: timestamp,
            eventType: eventType,
            replacementString: replacementString,
            rangeStart: rangeStart,
            rangeLength: rangeLength,
            expectedIndex: expectedIndex,
            keyLabel: tapInfo.keyLabel,
            tapLocalX: tapInfo.tapLocalX,
            tapLocalY: tapInfo.tapLocalY,
            keyWidth: tapInfo.keyWidth,
            keyHeight: tapInfo.keyHeight,
            keyRow: SessionManager.keyRow(for: tapInfo.keyLabel),
            keyCol: SessionManager.keyCol(for: tapInfo.keyLabel),
            expectedChar: expectedChar,
            actualChar: actualChar,
            correctedChar: correctedChar,
            isCorrect: isCorrect,
            previousKeyLabel: prevKey,
            textBefore: textBefore,
            textAfter: textAfter,
            interKeyIntervalMs: iki,
            sessionMode: sessionMode == .gaussian ? "gaussian" : "classic",
            studySessionIndex: studySessionIndex,
            trialIndex: trial.trialIndex
        )
    }
}

// MARK: - SessionManager

@Observable
final class SessionManager {
    // MARK: - State
    var participant: Participant?
    var currentSession: Session?
    var currentTrial: Trial?
    var currentTrialIndex: Int = 0
    var pendingRawEvents: [RawInputEvent] = []
    var pendingEvents: [InputEventData] = []
    // All events across the session, kept for export
    var allEvents: [InputEventData] = []
    // Holding-hand samples collected across the study (HandyTrak data collection)
    var pendingHandSamples: [HandSample] = []
    var isSessionActive: Bool = false
    var isTrialActive: Bool = false
    var isSessionComplete: Bool = false
    var completedTrials: [Trial] = []

    // Which hit-test model the keyboard is using this session.
    var sessionMode: SessionMode = .classic

    // Study-level state: total sessions chosen by researcher, split evenly classic/gaussian.
    var studyId: UUID = UUID()
    var totalStudySessions: Int = 4
    var completedStudySessions: Int = 0
    var isStudyComplete: Bool = false
    var studySessionSummaries: [StudySessionSummary] = []
    var studyDesign: StudyDesign = .classicAndAdaptive

    var currentSessionMode: SessionMode {
        switch studyDesign {
        case .classicOnly: return .classic
        case .classicAndAdaptive:
            return completedStudySessions < totalStudySessions / 2 ? .classic : .gaussian
        }
    }

    // Measured system keyboard height and safe area — set by ParticipantSetupView on first keyboard show
    var measuredKeyboardHeight: CGFloat = 291   // iPhone 16 default until measured
    var safeAreaBottom: CGFloat = 34            // iPhone 16 default until measured

    // Timer state
    var sessionDurationSeconds: Int = 300   // default 5 minutes
    var remainingSeconds: Int = 0
    var elapsedSeconds: Int = 0

    // Live metrics
    var liveTypedText: String = ""
    var liveWPM: Double = 0.0

    // Internal
    private var trialStartTime: Date?
    private var lastEventTimestamp: Date?
    private var lastKeyLabel: String = ""
    private var lastLiveWPMUpdateAt: Date?
    private var modelContext: ModelContext?
    private var sessionTimer: Timer?
    private var timerStarted: Bool = false

    // Continuous mode: enough sentences to outlast any session
    private static let initialSentenceCount = 20
    private static let liveWPMUpdateInterval: TimeInterval = 0.25

    // MARK: - Setup

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Session Lifecycle

    func startSession(participant: Participant,
                      durationSeconds: Int,
                      mode: SessionMode = .classic) {
        self.participant = participant
        self.sessionDurationSeconds = durationSeconds
        self.remainingSeconds = durationSeconds
        self.elapsedSeconds = 0
        self.sessionMode = mode

        // Cycle through corpus sets so each session uses a different text set.
        WordGenerator.selectCorpus(forSessionIndex: completedStudySessions)

        let session = Session(participantId: participant.id)
        self.currentSession = session
        modelContext?.insert(session)

        isSessionActive = true
        isSessionComplete = false
        completedTrials = []
        currentTrialIndex = 0
        timerStarted = false

        // Timer starts on first keypress, not here
        startNextTrial()
    }

    func startStudy(participant: Participant, totalSessions: Int, design: StudyDesign = .classicAndAdaptive) {
        totalStudySessions = totalSessions
        studyDesign = design
        completedStudySessions = 0
        isStudyComplete = false
        studyId = UUID()
        allEvents = []
        pendingHandSamples = []
        // IMU seam (decision 6 — OFF by default):
        // MotionRecorder.shared.start(sessionId: UUID(), studySessionIndex: 0)
        startSession(participant: participant, durationSeconds: 60, mode: currentSessionMode)
    }

    func continueToNextSession() {
        guard let p = participant else { return }
        startSession(participant: p, durationSeconds: 60, mode: currentSessionMode)
    }

    func endStudyEarly() {
        isStudyComplete = true
    }

    private func startTimer() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.remainingSeconds > 0 {
                self.remainingSeconds -= 1
                self.elapsedSeconds += 1
            } else {
                self.timeExpired()
            }
        }
    }

    private func timeExpired() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        if isTrialActive {
            submitTrial(finalText: liveTypedText)
        }
        finalizeSession()
    }

    func startNextTrial() {
        guard isSessionActive, remainingSeconds > 0 else {
            finalizeSession()
            return
        }
        guard let session = currentSession else { return }

        let targetText = WordGenerator.randomSentences(count: Self.initialSentenceCount)
        let trial = Trial(
            sessionId: session.id,
            trialIndex: currentTrialIndex,
            targetText: targetText
        )
        currentTrial = trial
        modelContext?.insert(trial)

        pendingRawEvents = []
        pendingEvents = []
        liveTypedText = ""
        liveWPM = 0.0
        trialStartTime = Date()
        lastEventTimestamp = nil
        lastKeyLabel = ""
        lastLiveWPMUpdateAt = nil
        isTrialActive = true
    }

    // MARK: - Event Logging

    func captureEvent(_ raw: RawInputEvent) {
        // Start countdown on first keystroke
        if !timerStarted {
            timerStarted = true
            trialStartTime = Date()
            startTimer()
        }

        pendingRawEvents.append(raw)
        liveTypedText = raw.textAfter

        // Keep target text well ahead of where the user is typing
        if let trial = currentTrial {
            let remaining = trial.targetText.count - raw.textAfter.count
            if remaining < 200 {
                trial.targetText += " " + WordGenerator.randomSentences(count: 8)
            }
        }

        if let start = trialStartTime {
            let elapsed = Date().timeIntervalSince(start) * 1000.0
            let shouldRefreshWPM: Bool
            if let last = lastLiveWPMUpdateAt {
                shouldRefreshWPM = raw.timestamp.timeIntervalSince(last) >= Self.liveWPMUpdateInterval
            } else {
                shouldRefreshWPM = true
            }
            if shouldRefreshWPM {
                liveWPM = MetricsComputer.wpm(charCount: raw.textAfter.count, durationMs: elapsed)
                lastLiveWPMUpdateAt = raw.timestamp
            }
        }
    }

    /// Record a holding-hand sample for later export.
    /// Persistence (modelContext.insert) is done by HandCaptureView; this
    /// mirrors the allEvents pattern for the exporter.
    func recordHandSample(_ sample: HandSample) {
        pendingHandSamples.append(sample)
    }

    // Compatibility path for callers that still build finalized events eagerly.
    func logEvent(_ data: InputEventData) {
        pendingEvents.append(data)
        allEvents.append(data)
        liveTypedText = data.textAfter
    }

    func buildEventData(
        textBefore: String,
        textAfter: String,
        replacementString: String,
        rangeStart: Int,
        rangeLength: Int,
        eventType: InputEventType
    ) -> InputEventData {
        captureRawKeyboardEvent(
            textBefore: textBefore,
            textAfter: textAfter,
            replacementString: replacementString,
            rangeStart: rangeStart,
            rangeLength: rangeLength,
            eventType: eventType,
            tapInfo: .none
        )
        .materialized(
            trial: currentTrial,
            session: currentSession,
            studyId: studyId,
            sessionMode: sessionMode,
            studySessionIndex: completedStudySessions,
            previousKeyLabel: &lastKeyLabel,
            previousTimestamp: &lastEventTimestamp
        )
    }

    func captureRawKeyboardEvent(
        textBefore: String,
        textAfter: String,
        replacementString: String,
        rangeStart: Int,
        rangeLength: Int,
        eventType: InputEventType,
        tapInfo: TapInfo
    ) -> RawInputEvent {
        RawInputEvent(
            timestamp: Date(),
            eventType: eventType,
            replacementString: replacementString,
            rangeStart: rangeStart,
            rangeLength: rangeLength,
            textBefore: textBefore,
            textAfter: textAfter,
            tapInfo: tapInfo
        )
    }

    func buildKeyboardEventData(
        textBefore: String,
        textAfter: String,
        replacementString: String,
        rangeStart: Int,
        rangeLength: Int,
        eventType: InputEventType,
        tapInfo: TapInfo
    ) -> InputEventData {
        captureRawKeyboardEvent(
            textBefore: textBefore,
            textAfter: textAfter,
            replacementString: replacementString,
            rangeStart: rangeStart,
            rangeLength: rangeLength,
            eventType: eventType,
            tapInfo: tapInfo
        )
        .materialized(
            trial: currentTrial,
            session: currentSession,
            studyId: studyId,
            sessionMode: sessionMode,
            studySessionIndex: completedStudySessions,
            previousKeyLabel: &lastKeyLabel,
            previousTimestamp: &lastEventTimestamp
        )
    }

    // MARK: - Key Row / Col Lookup

    fileprivate static func keyRow(for label: String) -> String {
        let top = Set(["q","w","e","r","t","y","u","i","o","p",
                       "1","2","3","4","5","6","7","8","9","0"])
        let mid = Set(["a","s","d","f","g","h","j","k","l",
                       "-","/",":",";","(",")","$","&","@","\""])
        let bot = Set(["z","x","c","v","b","n","m",
                       "delete",".",",","?","!","'"])
        if top.contains(label) { return "top" }
        if mid.contains(label) { return "middle" }
        if bot.contains(label) { return "bottom" }
        return "space"   // space, return, and unknown special keys
    }

    fileprivate static func keyCol(for label: String) -> Int? {
        let rows: [[String]] = [
            ["q","w","e","r","t","y","u","i","o","p"],
            ["a","s","d","f","g","h","j","k","l"],
            ["z","x","c","v","b","n","m"],
            ["1","2","3","4","5","6","7","8","9","0"],
            ["-","/",":",";","(",")","$","&","@","\""],
            [".",",","?","!","'"]
        ]
        for row in rows {
            if let idx = row.firstIndex(of: label) { return idx }
        }
        return nil
    }

    // MARK: - Trial Submission

    func submitTrial(finalText: String) {
        guard let trial = currentTrial, let start = trialStartTime else { return }

        var previousKey = ""
        var previousTimestamp: Date? = nil
        let finalizedEvents = pendingRawEvents.map {
            $0.materialized(
                trial: currentTrial,
                session: currentSession,
                studyId: studyId,
                sessionMode: sessionMode,
                studySessionIndex: completedStudySessions,
                previousKeyLabel: &previousKey,
                previousTimestamp: &previousTimestamp
            )
        }
        pendingEvents = finalizedEvents
        allEvents.append(contentsOf: finalizedEvents)

        let endTime = Date()
        let durationMs = endTime.timeIntervalSince(start) * 1000.0

        let cps = MetricsComputer.charsPerSecond(charCount: finalText.count, durationMs: durationMs)
        let wpmVal = MetricsComputer.wpm(charCount: finalText.count, durationMs: durationMs)

        let backspaces = pendingEvents.filter { $0.eventType == .delete }.count
        let inserts = pendingEvents.filter { $0.eventType == .insert }
        let correctChars = inserts.filter { $0.isCorrect }.count
        // Per-keystroke accuracy: fraction of insert taps that hit the correct key
        let accuracy = inserts.isEmpty ? 0.0 : Double(correctChars) / Double(inserts.count)

        trial.finalText = finalText
        trial.endedAt = endTime
        trial.durationMs = durationMs
        trial.backspaceCount = backspaces
        trial.insertCount = inserts.count
        trial.correctChars = correctChars
        trial.totalTargetChars = trial.targetText.count
        trial.accuracy = accuracy
        trial.charsPerSecond = cps
        trial.wpm = wpmVal

        completedTrials.append(trial)
        currentTrialIndex += 1
        isTrialActive = false

        if let session = currentSession {
            session.completedTrials = currentTrialIndex
            session.totalTrials = currentTrialIndex
        }
    }

    // MARK: - Session Finalization

    func finalizeSession() {
        sessionTimer?.invalidate()
        sessionTimer = nil

        persistAndExport(events: allEvents)

        if let session = currentSession {
            session.endedAt = Date()
            session.completedTrials = completedTrials.count
            session.totalTrials = completedTrials.count

            if !completedTrials.isEmpty {
                session.meanAccuracy = completedTrials.map(\.accuracy).reduce(0, +) / Double(completedTrials.count)
                session.meanCharsPerSecond = completedTrials.map(\.charsPerSecond).reduce(0, +) / Double(completedTrials.count)
                session.totalBackspaces = completedTrials.map(\.backspaceCount).reduce(0, +)
            }
        }

        let sessionWPM = completedTrials.isEmpty ? 0.0
            : completedTrials.map(\.wpm).reduce(0, +) / Double(completedTrials.count)

        let sessionEvents = allEvents.filter { $0.studySessionIndex == completedStudySessions }

        var flagCounts: [String: Int] = [:]
        var totalInserts = 0
        var uniqueFlagged = 0
        for e in sessionEvents where e.eventType != .delete {
            totalInserts += 1
            let result = KeystrokeCleaner.flag(e)
            if result.isOutlier { uniqueFlagged += 1 }
            for flag in result.flags {
                flagCounts[flag.rawValue, default: 0] += 1
            }
        }

        studySessionSummaries.append(StudySessionSummary(
            sessionIndex: completedStudySessions,
            mode: sessionMode == .gaussian ? "gaussian" : "classic",
            meanAccuracy: currentSession?.meanAccuracy ?? 0,
            meanWPM: sessionWPM,
            totalBackspaces: currentSession?.totalBackspaces ?? 0,
            totalInserts: totalInserts,
            flagCounts: flagCounts,
            uniqueFlaggedInserts: uniqueFlagged
        ))

        isSessionActive = false
        isTrialActive = false
        isSessionComplete = true
        BackendClient.shared.flush()
        // IMU seam (decision 6 — OFF by default):
        // let _ = MotionRecorder.shared.stop()
        try? modelContext?.save()

        // Only classic sessions train the model — Gaussian sessions run on the
        // frozen snapshot built from the first half of the study.
        if sessionMode == .classic {
            GaussianModelStore.shared.update(with: sessionEvents)
        }

        completedStudySessions += 1
        if completedStudySessions >= totalStudySessions {
            isStudyComplete = true
        }
    }

    private func persistAndExport(events: [InputEventData]) {
        for data in events {
            let event = InputEvent(
                trialId: data.trialId,
                timestamp: data.timestamp,
                eventType: data.eventType,
                replacementString: data.replacementString,
                rangeStart: data.rangeStart,
                rangeLength: data.rangeLength,
                textBefore: data.textBefore,
                textAfter: data.textAfter,
                expectedIndex: data.expectedIndex,
                expectedChar: data.expectedChar,
                actualChar: data.actualChar,
                isCorrect: data.isCorrect,
                interKeyIntervalMs: data.interKeyIntervalMs,
                tapLocalX: data.tapLocalX,
                tapLocalY: data.tapLocalY,
                tapNormX: data.tapNormX,
                tapNormY: data.tapNormY,
                keyLabel: data.keyLabel,
                keyScreenX: data.keyScreenX,
                keyScreenY: data.keyScreenY,
                keyWidth: data.keyWidth,
                keyHeight: data.keyHeight
            )
            modelContext?.insert(event)

            if let session = currentSession, let participant = participant {
                BackendClient.shared.enqueue(
                    event: data,
                    sessionId: session.id,
                    participantId: participant.id
                )
            }
        }
    }

    // MARK: - Reset

    // Restart the full study with the same participant.
    func restartSameSession() {
        guard let p = participant else { return }
        let total = totalStudySessions
        reset()
        startStudy(participant: p, totalSessions: total)
    }

    func reset() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        participant = nil
        currentSession = nil
        currentTrial = nil
        currentTrialIndex = 0
        pendingRawEvents = []
        pendingEvents = []
        allEvents = []
        pendingHandSamples = []
        isSessionActive = false
        isTrialActive = false
        isSessionComplete = false
        completedTrials = []
        liveTypedText = ""
        liveWPM = 0.0
        trialStartTime = nil
        lastEventTimestamp = nil
        lastKeyLabel = ""
        lastLiveWPMUpdateAt = nil
        totalStudySessions = 4
        studyDesign = .classicAndAdaptive
        completedStudySessions = 0
        isStudyComplete = false
        studySessionSummaries = []
        studyId = UUID()
    }

    // MARK: - Formatted time

    var formattedRemaining: String {
        let m = remainingSeconds / 60
        let s = remainingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    var formattedDuration: String {
        let m = sessionDurationSeconds / 60
        let s = sessionDurationSeconds % 60
        if s == 0 { return "\(m) min" }
        return String(format: "%d:%02d", m, s)
    }
}
