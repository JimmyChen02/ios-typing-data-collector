import Foundation
import SwiftData
import Observation
import CoreGraphics
import UIKit

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

enum StudyRole: Sendable {
    case participant
    case researcher
}

enum StudyPhase: String, Sendable {
    case phaseA = "Phase A"
    case phaseB = "Phase B"
}

struct ScheduledStudySession: Sendable {
    let phase: StudyPhase
    let posture: HoldingHand
    let mode: SessionMode
}

enum StudyTopic: String, CaseIterable, Identifiable, Sendable {
    var id: String { rawValue }

    case weekdayMorning = "A typical weekday morning"
    case favoriteMeal = "Your favorite meal and how you make it"
    case memorableTrip = "A trip you remember well"
    case phoneHabits = "How you use your phone during the day"
    case hobby = "A hobby you enjoy and why"
    case commute = "Your commute or how you get around"
    case showRecommend = "A movie or show you would recommend"
    case howYouRelax = "What you do to relax after a long day"
    case importantPerson = "A friend or family member who matters to you"
    case favoriteSeason = "Your favorite season and why"
    case skillToLearn = "A skill you want to learn"
    case recentLunch = "What you ate recently and whether you liked it"
    case cityPlace = "A place in your city you like to go"
    case stayingActive = "How you stay active"
    case bookOrPodcast = "A book, podcast, or video you liked"
    case weekendRoutine = "Your usual weekend routine"
    case weather = "Weather you like and weather you hate"
    case jobOrClass = "A job, class, or project you have worked on"
    case music = "Music you listen to and when you play it"
    case recentProblem = "A small problem you solved recently"
    case animals = "Pets or animals you like"
    case groceries = "How you shop for groceries"
    case goodDay = "What makes a good day for you"
    case stayingInTouch = "How you stay in touch with people"
    case childhoodMemory = "A childhood memory you still think about"
    case foodFromHome = "Food you miss from home or from growing up"
    case nextMonth = "Plans you have for the next month"
    case madeYouLaugh = "Something that made you laugh recently"
    case techAtWork = "How you use technology at work or school"
    case advicePastSelf = "Advice you would give your past self"
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
    let editSource: String         // key, candidate, autocorrection, etc.
    let editKind: String           // insert, delete, or replace lineage
    let originalText: String
    let emittedText: String
    let touchGestureJSON: String   // full coordinates/radius/force/timing samples
    let suggestionsOffered: String // pipe-separated suggestion bar texts
    let selectedSuggestion: String // tapped/autocorrected suggestion, if any

    // Computed for legacy exporter compatibility (not exported to CSV)
    var tapNormX: Double { keyWidth  > 0 ? tapLocalX / keyWidth  : 0.5 }
    var tapNormY: Double { keyHeight > 0 ? tapLocalY / keyHeight : 0.5 }
    var keyScreenX: Double { 0 }
    var keyScreenY: Double { 0 }
}

struct EditBehaviorAnnotation: Sendable {
    let eventIndex: Int
    let category: String
    let intentPreserved: Bool
    let cursorMoved: Bool
    let usedAutocorrect: Bool
    let usedSuggestion: Bool
    let wrongfullyTypedToken: String
    let llmEditedToken: String
    let intendedKey: String
    let boundaryNote: String
}

enum EditBehaviorAnnotator {
    static func annotate(events: [InputEventData]) -> [EditBehaviorAnnotation] {
        guard !events.isEmpty else { return [] }
        let resolved = KeyboardIntentResolver.resolve(events: events)
        var rows: [EditBehaviorAnnotation] = []
        rows.reserveCapacity(events.count)

        for (idx, e) in events.enumerated() {
            let usedAutocorrect = e.editSource == "autocorrection"
            let usedSuggestion = e.editSource == "candidate" && !e.selectedSuggestion.isEmpty
            let cursorMoved = eventLikelyMovedCursor(e)
            let resolvedKind = resolved.eventKind[idx] ?? resolved.tapKind[idx]
            let intentPreserved: Bool = {
                if let resolvedKind {
                    return resolvedKind != .changedMind
                }
                return inferIntentPreserved(event: e, index: idx, events: events)
            }()
            let wrongToken = resolved.typedWord[idx] ?? inferWrongToken(event: e)
            let editedToken = resolved.finalWord[idx].flatMap { $0.isEmpty ? nil : $0 }
                ?? inferEditedToken(event: e)

            let category: String = {
                if e.editSource == "correctionReversion" {
                    return "llm_autocorrect_reverted"
                }
                if usedAutocorrect {
                    return "llm_autocorrect_applied"
                }
                if usedSuggestion {
                    return "llm_suggestion_applied"
                }
                if resolvedKind == .lmWrongUserFixed {
                    return "llm_wrong_then_user_fixed"
                }
                if resolvedKind == .typoFixSameWord, e.eventType == .delete {
                    return "backspace_same_intent_correction"
                }
                if e.eventType == .delete {
                    return intentPreserved
                        ? "backspace_same_intent_correction"
                        : "backspace_intent_change_or_cleanup"
                }
                if cursorMoved {
                    return intentPreserved
                        ? "cursor_move_same_intent_edit"
                        : "cursor_move_intent_change_edit"
                }
                if e.eventType == .replace {
                    return intentPreserved
                        ? "replace_same_intent_edit"
                        : "replace_intent_change_edit"
                }
                return "normal_typing"
            }()

            rows.append(
                EditBehaviorAnnotation(
                    eventIndex: idx,
                    category: category,
                    intentPreserved: intentPreserved,
                    cursorMoved: cursorMoved,
                    usedAutocorrect: usedAutocorrect,
                    usedSuggestion: usedSuggestion,
                    wrongfullyTypedToken: wrongToken,
                    llmEditedToken: editedToken,
                    intendedKey: resolved.intendedKey[idx] ?? "",
                    boundaryNote: resolved.note[idx] ?? ""
                )
            )
        }
        return rows
    }

    private static func eventLikelyMovedCursor(_ e: InputEventData) -> Bool {
        switch e.eventType {
        case .insert, .replace:
            return e.rangeStart < e.textBefore.count
        case .delete:
            return e.rangeStart < max(0, e.textBefore.count - 1)
        case .paste:
            return e.rangeStart < e.textBefore.count
        }
    }

    private static func inferIntentPreserved(
        event e: InputEventData,
        index: Int,
        events: [InputEventData]
    ) -> Bool {
        if e.editSource == "autocorrection" || e.editSource == "correctionReversion" {
            return true
        }
        if e.eventType == .delete {
            let deleted = !e.originalText.isEmpty ? e.originalText : e.correctedChar
            if deleted.count == 1,
               let next = nextEdit(after: index, events: events),
               next.eventType != .delete,
               next.emittedText.count == 1,
               deleted.rangeOfCharacter(from: .letters) != nil,
               next.emittedText.rangeOfCharacter(from: .letters) != nil {
                return true
            }
            return false
        }
        let a = normalizedToken(e.originalText)
        let b = normalizedToken(e.emittedText)
        if a.isEmpty || b.isEmpty { return true }
        let distance = levenshtein(a, b)
        let limit = max(1, min(2, max(a.count, b.count) / 3))
        return distance <= limit
    }

    private static func inferWrongToken(event e: InputEventData) -> String {
        if !e.originalText.isEmpty { return e.originalText }
        if e.editSource == "autocorrection" || e.editSource == "candidate" {
            return tokenBeforeCursor(in: e.textBefore, rangeStart: e.rangeStart)
        }
        return ""
    }

    private static func inferEditedToken(event e: InputEventData) -> String {
        if !e.emittedText.isEmpty { return e.emittedText }
        if e.editSource == "autocorrection" || e.editSource == "candidate" {
            return tokenBeforeCursor(in: e.textAfter, rangeStart: e.rangeStart)
        }
        return ""
    }

    private static func nextEdit(after index: Int, events: [InputEventData]) -> InputEventData? {
        guard index + 1 < events.count else { return nil }
        return events[(index + 1)...].first { !$0.emittedText.isEmpty || $0.eventType == .delete }
    }

    private static func tokenBeforeCursor(in text: String, rangeStart: Int) -> String {
        let ns = text as NSString
        let cursor = max(0, min(rangeStart, ns.length))
        guard cursor > 0 else { return "" }
        var start = cursor
        while start > 0 {
            let ch = ns.character(at: start - 1)
            if ch == 32 || ch == 10 || ch == 9 { break }
            start -= 1
        }
        let token = ns.substring(with: NSRange(location: start, length: cursor - start))
        return token.trimmingCharacters(in: .punctuationCharacters)
    }

    private static func normalizedToken(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
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

    static func categoryTitle(_ category: String) -> String {
        switch category {
        case "llm_autocorrect_applied": return "LM autocorrect"
        case "llm_suggestion_applied": return "Suggestion tap"
        case "llm_autocorrect_reverted": return "Tapped word to undo autocorrect"
        case "llm_wrong_then_user_fixed": return "LM was wrong; user fixed the word"
        case "backspace_same_intent_correction": return "Typo fix (same word)"
        case "backspace_intent_change_or_cleanup": return "Changed their mind (deleted a different word)"
        case "cursor_move_same_intent_edit": return "Typed after moving caret (same word)"
        case "cursor_move_intent_change_edit": return "Typed after moving caret (different word)"
        case "replace_same_intent_edit": return "Replace (same word)"
        case "replace_intent_change_edit": return "Replace (different word)"
        case "normal_typing": return "Normal typing"
        default: return category.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func cursorEditKind(for event: InputEventData) -> String? {
        if event.editSource == "correctionReversion" {
            return "Tapped the underlined word"
        }
        let beforeLen = (event.textBefore as NSString).length
        if event.eventType == .delete {
            let delLen = max((event.originalText as NSString).length, 1)
            if event.rangeStart + delLen >= beforeLen {
                return "Backspace at the end"
            }
            return "Backspace after moving the caret"
        }
        if event.eventType == .insert || event.eventType == .replace {
            if event.editSource == "key", event.rangeStart < beforeLen {
                return "Typed after moving the caret (tap or Space-trackpad)"
            }
        }
        return nil
    }
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
    let editSource: String
    let editKind: String
    let originalText: String
    let emittedText: String
    let touchGestureJSON: String
    let suggestionsOffered: String
    let selectedSuggestion: String
}

// MARK: - StudySessionSummary

struct StudySessionSummary: Identifiable {
    // Unique identity: posture training runs are back-to-back 1-session
    // studies, so sessionIndex repeats (always 0) across runs and can't
    // be used as a ForEach id.
    let id = UUID()
    let sessionIndex: Int   // 0-based within its run
    let mode: String        // "classic" or "gaussian"
    let phase: String       // "Phase A" / "Phase B"
    let posture: String?    // holding-posture label for posture training runs, else nil
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
            trialIndex: trial.trialIndex,
            editSource: editSource,
            editKind: editKind,
            originalText: originalText,
            emittedText: emittedText,
            touchGestureJSON: touchGestureJSON,
            suggestionsOffered: suggestionsOffered,
            selectedSuggestion: selectedSuggestion
        )
    }
}

// MARK: - SessionManager

// @MainActor: SessionManager is only ever driven from SwiftUI (main-actor)
// call sites; this annotation was added alongside D2b so the @MainActor
// PostureCaptureController (which wraps @MainActor HandBurstCapture) can be
// stored/called directly without extra actor-hopping boilerplate. The
// Task.detached(...) blocks in SessionView.swift (PDF/Gaussian-preview
// rendering) do not call back into SessionManager from inside the detached
// closure, so they are unaffected by this change.
@MainActor
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
    var isAwaitingSessionStart: Bool = false
    var completedTrials: [Trial] = []

    // MARK: - Posture training run (D2) — opt-in, off by default
    //
    // Set by PostureSelectView before the following typing session starts.
    // isPostureTrainingRun gates ALL of the continuous labeled-capture
    // behavior below; default false so normal timed studies are completely
    // unaffected (see the D2 spec's research-integrity requirement — every
    // new hook in this file and in TrialView is guarded on this flag).
    var selectedPosture: HoldingHand = .unknown
    var isPostureTrainingRun: Bool = false

    // Which hit-test model the keyboard is using this session.
    var sessionMode: SessionMode = .classic

    // Study-level state: total sessions chosen by researcher, split evenly classic/gaussian.
    var studyId: UUID = UUID()
    var totalStudySessions: Int = 24
    var completedStudySessions: Int = 0
    var isStudyComplete: Bool = false
    var studySessionSummaries: [StudySessionSummary] = []
    var studyDesign: StudyDesign = .classicAndAdaptive
    var studyRole: StudyRole = .participant
    var sessionsPerHandPerPhase: Int = 4
    var scheduledSessions: [ScheduledStudySession] = []
    var isAnalyzingPhaseTransition: Bool = false
    var hasCompletedPhaseAAnalysis: Bool = false
    var phaseBModelSnapshotDate: Date?
    var randomizationSeed: Int = Int(Date().timeIntervalSince1970)
    var currentSessionTopic: StudyTopic = .weekdayMorning
    var selectedTopicForNextSession: StudyTopic = .weekdayMorning
    var isFreeTypingStudy: Bool = true

    var currentSessionMode: SessionMode {
        guard completedStudySessions < scheduledSessions.count else { return .classic }
        return scheduledSessions[completedStudySessions].mode
    }

    var currentStudyPhase: StudyPhase {
        guard completedStudySessions < scheduledSessions.count else { return .phaseB }
        return scheduledSessions[completedStudySessions].phase
    }

    var currentAssignedPosture: HoldingHand {
        guard completedStudySessions < scheduledSessions.count else { return .both }
        return scheduledSessions[completedStudySessions].posture
    }

    var phaseASessionCount: Int {
        scheduledSessions.filter { $0.phase == .phaseA }.count
    }

    var phaseBSessionCount: Int {
        scheduledSessions.filter { $0.phase == .phaseB }.count
    }

    var currentPhaseSessionNumber: Int {
        let targetPhase = currentStudyPhase
        let completedInPhase = scheduledSessions
            .prefix(completedStudySessions)
            .filter { $0.phase == targetPhase }
            .count
        return completedInPhase + 1
    }

    var currentPhaseTotalSessions: Int {
        currentStudyPhase == .phaseA ? phaseASessionCount : phaseBSessionCount
    }

    var isAwaitingPhaseBAnalysis: Bool {
        !hasCompletedPhaseAAnalysis &&
        completedStudySessions == phaseASessionCount &&
        completedStudySessions < totalStudySessions
    }

    // Device-adaptive keyboard chrome — updated from SystemKeyboardMetrics /
    // live system-keyboard measurement so each iPhone model matches itself.
    var measuredKeyboardHeight: CGFloat = SystemKeyboardMetrics.totalDockedHeight()
    var safeAreaBottom: CGFloat = SystemKeyboardMetrics.bottomSafeAreaInset()

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
    private var currentTargetTextLength: Int = 0

    // Posture training run (D2b) — owns the background HandBurstCapture +
    // per-frame counter for the typing screen. Only touched when
    // isPostureTrainingRun == true.
    private let postureCapture = PostureCaptureController()

    // Continuous mode: enough sentences to outlast any session
    private static let initialSentenceCount = 20
    private static let liveWPMUpdateInterval: TimeInterval = 0.25

    // MARK: - Setup

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    private func makeSchedule(
        design: StudyDesign,
        sessionsPerHand: Int,
        seed: Int
    ) -> [ScheduledStudySession] {
        let postures: [HoldingHand] = [.left, .right, .both]
        var rng = SeededGenerator(seed: UInt64(bitPattern: Int64(seed)))

        func shuffledPhase(phase: StudyPhase, mode: SessionMode) -> [ScheduledStudySession] {
            var chunk: [ScheduledStudySession] = []
            for posture in postures {
                for _ in 0..<sessionsPerHand {
                    chunk.append(ScheduledStudySession(phase: phase, posture: posture, mode: mode))
                }
            }
            chunk.shuffle(using: &rng)
            return chunk
        }

        switch design {
        case .classicOnly:
            return shuffledPhase(phase: .phaseA, mode: .classic)
        case .classicAndAdaptive:
            return shuffledPhase(phase: .phaseA, mode: .classic)
                + shuffledPhase(phase: .phaseB, mode: .gaussian)
        }
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
        self.currentSessionTopic = selectedTopicForNextSession

        // Cycle through corpus sets so each session uses a different text set.
        WordGenerator.selectCorpus(forSessionIndex: completedStudySessions)

        let assignedPosture = currentAssignedPosture == .both ? "Both hands" : currentAssignedPosture.displayName
        let session = Session(
            participantId: participant.id,
            phaseLabel: currentStudyPhase.rawValue,
            assignedPosture: assignedPosture
        )
        self.currentSession = session
        MotionRecorder.shared.start(sessionId: session.id, studySessionIndex: completedStudySessions)
        modelContext?.insert(session)

        isSessionActive = true
        isSessionComplete = false
        completedTrials = []
        currentTrialIndex = 0
        timerStarted = false

        // Timer starts on first keypress, not here
        startNextTrial()
    }

    func startStudy(
        participant: Participant,
        totalSessions: Int? = nil,
        design: StudyDesign = .classicAndAdaptive,
        role: StudyRole = .participant,
        sessionsPerHandPerPhase: Int = 4,
        randomizationSeed: Int = Int(Date().timeIntervalSince1970),
        initialTopic: StudyTopic = .weekdayMorning
    ) {
        studyRole = role
        self.sessionsPerHandPerPhase = max(1, sessionsPerHandPerPhase)
        self.randomizationSeed = randomizationSeed
        studyDesign = design
        scheduledSessions = makeSchedule(
            design: design,
            sessionsPerHand: self.sessionsPerHandPerPhase,
            seed: randomizationSeed
        )
        if let totalSessions {
            totalStudySessions = totalSessions
            scheduledSessions = Array(scheduledSessions.prefix(totalSessions))
        } else {
            totalStudySessions = scheduledSessions.count
        }
        completedStudySessions = 0
        isStudyComplete = false
        isAnalyzingPhaseTransition = false
        hasCompletedPhaseAAnalysis = false
        phaseBModelSnapshotDate = nil
        studyId = UUID()
        allEvents = []
        pendingHandSamples = []
        selectedTopicForNextSession = initialTopic
        currentSessionTopic = initialTopic
        self.participant = participant
        isSessionActive = false
        isSessionComplete = false
        isAwaitingSessionStart = true
    }

    func continueToNextSession() {
        guard participant != nil else { return }
        if isAwaitingPhaseBAnalysis { return }
        isSessionComplete = false
        isAwaitingSessionStart = true
    }

    func beginPreparedSession() {
        guard let p = participant else { return }
        isAwaitingSessionStart = false
        startSession(participant: p, durationSeconds: 60, mode: currentSessionMode)
    }

    func setNextSessionTopic(_ topic: StudyTopic) {
        selectedTopicForNextSession = topic
    }

    func runPhaseAAnalysisAndPreparePhaseB() {
        guard isAwaitingPhaseBAnalysis else { return }
        isAnalyzingPhaseTransition = true
        // Persist an explicit snapshot marker right after Phase A to freeze
        // the adaptation state used for Phase B evaluation.
        if GaussianModelStore.shared.savePhaseBSnapshot() {
            phaseBModelSnapshotDate = Date()
        }
        hasCompletedPhaseAAnalysis = true
        isAnalyzingPhaseTransition = false
    }

    func endStudyEarly() {
        isStudyComplete = true
    }

    private func startTimer() {
        sessionTimer?.invalidate()
        // Timer's closure is not statically guaranteed @MainActor by the
        // compiler even though it fires on the main run loop in practice;
        // hop explicitly (same pattern used elsewhere in this file, e.g.
        // PosturePredictor's prediction timer) now that SessionManager
        // itself is @MainActor-isolated (added alongside D2b).
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.remainingSeconds > 0 {
                    self.remainingSeconds -= 1
                    self.elapsedSeconds += 1
                } else {
                    self.timeExpired()
                }
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

        let targetText = isFreeTypingStudy ? "" : WordGenerator.randomSentences(count: Self.initialSentenceCount)
        let trial = Trial(
            sessionId: session.id,
            trialIndex: currentTrialIndex,
            targetText: targetText
        )
        currentTrial = trial
        currentTargetTextLength = targetText.count
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
        if !isFreeTypingStudy, let trial = currentTrial {
            let remaining = currentTargetTextLength - raw.textAfter.count
            if remaining < 200 {
                let extensionText = " " + WordGenerator.randomSentences(count: 8)
                trial.targetText += extensionText
                currentTargetTextLength += extensionText.count
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

    // MARK: - Posture training run (D2b) — background labeled capture
    //
    // Guarded on isPostureTrainingRun; TrialView calls these on
    // appear/disappear. Capture runs strictly in the background — it never
    // touches keystroke logging, timers, or event flow, preserving normal
    // session data integrity.

    /// Starts continuous labeled front-camera capture for the typing screen.
    /// Runs on every study session (left / right / both), not only the
    /// optional researcher posture-training pass. MotionRecorder is NOT
    /// started here — it already starts in startSession().
    func startPostureCapture() {
        guard let participant, let modelContext, isSessionActive else { return }

        let posture = isPostureTrainingRun ? selectedPosture : currentAssignedPosture
        postureCapture.start(
            participant: participant,
            sessionId: currentSession?.id,
            studyId: studyId,
            posture: posture,
            modelContext: modelContext,
            notes: isPostureTrainingRun ? "posture_training_run" : "study_session"
        ) { [weak self] sample in
            guard let self else { return }
            self.pendingHandSamples.append(sample)
        }
    }

    /// Stops continuous labeled capture. Idempotent (mirrors
    /// HandBurstCapture.stop()'s idempotency). Frames already saved are
    /// KEPT — unlike HandCaptureView's discard-on-early-dismiss, posture
    /// training run frames are real training data and an early dismiss of
    /// the typing screen should not lose them (intentional difference,
    /// documented here and in TrialView).
    func stopPostureCapture() {
        postureCapture.stop()
    }

    /// Starts another one-session posture training run with the same
    /// participant, so all three postures (L / R / Mid) can be collected
    /// back-to-back from the summary screen. pendingHandSamples is preserved
    /// across runs (startStudy clears it) so every run's frames land in ONE
    /// hand-data zip; the manifest carries per-sample sessionId + posture
    /// labels, and the zip already bundles all images and all per-session
    /// IMU CSVs.
    func startNextPostureRun(posture: HoldingHand) {
        guard let p = participant else { return }
        let accumulatedSamples = pendingHandSamples
        selectedPosture = posture
        isPostureTrainingRun = true
        startStudy(
            participant: p,
            totalSessions: 1,
            design: .classicOnly,
            initialTopic: selectedTopicForNextSession
        )
        pendingHandSamples = accumulatedSamples
    }

    /// Latest front-camera frame for the live preview overlay.
    var latestPostureFrame: UIImage? {
        postureCapture.latestFrame
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
        tapInfo: TapInfo,
        editSource: String = "key",
        editKind: String = "",
        originalText: String = "",
        emittedText: String = "",
        touchGestureJSON: String = "",
        suggestionsOffered: String = "",
        selectedSuggestion: String = ""
    ) -> RawInputEvent {
        RawInputEvent(
            timestamp: Date(),
            eventType: eventType,
            replacementString: replacementString,
            rangeStart: rangeStart,
            rangeLength: rangeLength,
            textBefore: textBefore,
            textAfter: textAfter,
            tapInfo: tapInfo,
            editSource: editSource,
            editKind: editKind,
            originalText: originalText,
            emittedText: emittedText,
            touchGestureJSON: touchGestureJSON,
            suggestionsOffered: suggestionsOffered,
            selectedSuggestion: selectedSuggestion
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

    // nonisolated: called from RawInputEvent.materialized(...), a free
    // (non-main-actor) extension method — these are pure, stateless lookups
    // so opting out of SessionManager's @MainActor isolation is safe.
    fileprivate nonisolated static func keyRow(for label: String) -> String {
        if topRowLabels.contains(label) { return "top" }
        if middleRowLabels.contains(label) { return "middle" }
        if bottomRowLabels.contains(label) { return "bottom" }
        return "space"   // space, return, and unknown special keys
    }

    fileprivate nonisolated static func keyCol(for label: String) -> Int? {
        for row in keyColumnRows {
            if let idx = row.firstIndex(of: label) { return idx }
        }
        return nil
    }

    private nonisolated static let topRowLabels: Set<String> = [
        "q","w","e","r","t","y","u","i","o","p",
        "1","2","3","4","5","6","7","8","9","0"
    ]
    private nonisolated static let middleRowLabels: Set<String> = [
        "a","s","d","f","g","h","j","k","l",
        "-","/",":",";","(",")","$","&","@","\""
    ]
    private nonisolated static let bottomRowLabels: Set<String> = [
        "z","x","c","v","b","n","m",
        "delete",".",",","?","!","'"
    ]
    private nonisolated static let keyColumnRows: [[String]] = [
        ["q","w","e","r","t","y","u","i","o","p"],
        ["a","s","d","f","g","h","j","k","l"],
        ["z","x","c","v","b","n","m"],
        ["1","2","3","4","5","6","7","8","9","0"],
        ["-","/",":",";","(",")","$","&","@","\""],
        [".",",","?","!","'"]
    ]

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
        let correctChars: Int
        let accuracy: Double
        if isFreeTypingStudy {
            // Free-typing heuristic: penalize corrections by backspace load.
            let estimatedCorrect = max(0, inserts.count - backspaces)
            correctChars = estimatedCorrect
            accuracy = inserts.isEmpty ? 0.0 : Double(estimatedCorrect) / Double(inserts.count)
        } else {
            correctChars = inserts.filter { $0.isCorrect }.count
            accuracy = inserts.isEmpty ? 0.0 : Double(correctChars) / Double(inserts.count)
        }

        trial.finalText = finalText
        trial.endedAt = endTime
        trial.durationMs = durationMs
        trial.backspaceCount = backspaces
        trial.insertCount = inserts.count
        trial.correctChars = correctChars
        trial.totalTargetChars = max(trial.targetText.count, finalText.count)
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
        let sessionAnnotations = EditBehaviorAnnotator.annotate(events: sessionEvents)

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
            phase: currentStudyPhase.rawValue,
            posture: isPostureTrainingRun
                ? (selectedPosture == .both ? "Mid" : selectedPosture.displayName)
                : currentAssignedPosture.displayName,
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
        let _ = MotionRecorder.shared.stop()
        try? modelContext?.save()

        // Only classic sessions train the model — Gaussian sessions run on the
        // frozen snapshot built from the first half of the study.
        if sessionMode == .classic {
            GaussianModelStore.shared.update(with: sessionEvents, annotations: sessionAnnotations)
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
                keyHeight: data.keyHeight,
                editSource: data.editSource,
                editKind: data.editKind,
                originalText: data.originalText,
                emittedText: data.emittedText,
                touchGestureJSON: data.touchGestureJSON,
                suggestionsOffered: data.suggestionsOffered,
                selectedSuggestion: data.selectedSuggestion
            )
            modelContext?.insert(event)
        }
    }

    // MARK: - Reset

    // Restart the full study with the same participant.
    func restartSameSession() {
        guard let p = participant else { return }
        let design = studyDesign
        let role = studyRole
        let perHand = sessionsPerHandPerPhase
        let seed = randomizationSeed
        reset()
        startStudy(
            participant: p,
            totalSessions: nil,
            design: design,
            role: role,
            sessionsPerHandPerPhase: perHand,
            randomizationSeed: seed,
            initialTopic: selectedTopicForNextSession
        )
    }

    func reset() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        postureCapture.stop()
        selectedPosture = .unknown
        isPostureTrainingRun = false
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
        isAwaitingSessionStart = false
        completedTrials = []
        liveTypedText = ""
        liveWPM = 0.0
        trialStartTime = nil
        lastEventTimestamp = nil
        lastKeyLabel = ""
        lastLiveWPMUpdateAt = nil
        currentTargetTextLength = 0
        totalStudySessions = 24
        studyDesign = .classicAndAdaptive
        completedStudySessions = 0
        isStudyComplete = false
        studySessionSummaries = []
        studyId = UUID()
        studyRole = .participant
        sessionsPerHandPerPhase = 4
        scheduledSessions = []
        isAnalyzingPhaseTransition = false
        hasCompletedPhaseAAnalysis = false
        phaseBModelSnapshotDate = nil
        randomizationSeed = Int(Date().timeIntervalSince1970)
        currentSessionTopic = .weekdayMorning
        selectedTopicForNextSession = .weekdayMorning
        isFreeTypingStudy = true
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

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
