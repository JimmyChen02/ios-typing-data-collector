import XCTest
import SwiftData
@testable import TypingResearch

/// Covers SessionManager's Free Writing Mode path per .pipeline/spec.md and
/// the Tester focus areas called out in .pipeline/changes.md:
///   1. Shuffle Prompt unlocked pre-typing / locked after first keystroke.
///   2. Edge case 1 — no keystrokes typed, "End Early" always finalizes.
///   3. Edge case 2 — End Early race with timer expiry (no double-finalize).
///   4. Edge case 3 — Cancel from start screen leaves no dangling state.
///   5. Study/trial isolation — the free-writing guard is a no-op when
///      isFreeWritingActive == false.
@MainActor
final class SessionManagerFreeWritingTests: XCTestCase {

    // ModelContext does not keep its ModelContainer alive; the container
    // must be retained for as long as the context (and any SessionManager
    // using it) is in use, or SwiftData traps on first access. Retaining it
    // per-test-instance here (each test method gets a fresh XCTestCase).
    private var retainedContainers: [ModelContainer] = []

    private func makeManager() -> SessionManager {
        let schema = Schema([Participant.self, Session.self, Trial.self, InputEvent.self, HandSample.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        retainedContainers.append(container)
        let manager = SessionManager()
        manager.configure(modelContext: container.mainContext)
        return manager
    }

    private func makeParticipant() -> Participant {
        Participant(
            firstName: "Test",
            lastName: "Participant",
            deviceModel: "iPhone",
            systemVersion: "17.0",
            screenWidthPt: 390,
            screenHeightPt: 844,
            appVersion: "1.0"
        )
    }

    // MARK: - Happy path: startFreeWriting

    func testStartFreeWriting_setsExpectedInitialState() {
        let manager = makeManager()
        let participant = makeParticipant()

        manager.startFreeWriting(participant: participant)

        XCTAssertTrue(manager.isFreeWritingActive)
        XCTAssertFalse(manager.isFreeWritingComplete)
        XCTAssertFalse(manager.freeWritingPrompt.isEmpty)
        XCTAssertTrue(FreeWritingPrompts.all.contains(manager.freeWritingPrompt))
        XCTAssertEqual(manager.sessionDurationSeconds, 180)
        XCTAssertEqual(manager.remainingSeconds, 180)
        XCTAssertEqual(manager.formattedRemaining, "3:00")
        XCTAssertNotNil(manager.currentSession)
        XCTAssertNotNil(manager.currentTrial)
        XCTAssertEqual(manager.currentTrial?.targetText, manager.freeWritingPrompt)
        XCTAssertTrue(manager.freeWritingEvents.isEmpty)
    }

    // MARK: - Tester focus #1: Shuffle Prompt behavior

    func testReshuffleFreeWritingPrompt_freelyChangesBeforeTypingStarts() {
        let manager = makeManager()
        manager.startFreeWriting(participant: makeParticipant())

        var seen = Set<String>()
        for _ in 0..<50 {
            manager.reshuffleFreeWritingPrompt()
            seen.insert(manager.freeWritingPrompt)
        }

        XCTAssertGreaterThan(seen.count, 1, "shuffle should be free to vary before the first keystroke")
        for prompt in seen {
            XCTAssertTrue(FreeWritingPrompts.all.contains(prompt))
        }
    }

    func testReshuffleFreeWritingPrompt_locksAfterFirstKeystroke() {
        let manager = makeManager()
        manager.startFreeWriting(participant: makeParticipant())

        // Simulate the first keystroke — this is the "typing began" signal.
        manager.captureFreeWritingEvent(
            textBefore: "", textAfter: "a", replacementString: "a",
            rangeStart: 0, rangeLength: 0, eventType: .insert
        )
        let lockedPrompt = manager.freeWritingPrompt

        for _ in 0..<50 {
            manager.reshuffleFreeWritingPrompt()
            XCTAssertEqual(manager.freeWritingPrompt, lockedPrompt, "prompt must not change once typing has begun")
        }
    }

    // MARK: - Happy path: captureFreeWritingEvent

    func testCaptureFreeWritingEvent_recordsFreeWritingSessionModeAndFields() {
        let manager = makeManager()
        manager.startFreeWriting(participant: makeParticipant())

        manager.captureFreeWritingEvent(
            textBefore: "hi", textAfter: "hi!", replacementString: "!",
            rangeStart: 2, rangeLength: 0, eventType: .insert
        )

        XCTAssertEqual(manager.freeWritingEvents.count, 1)
        let event = manager.freeWritingEvents[0]
        XCTAssertEqual(event.sessionMode, "free_writing")
        XCTAssertEqual(event.textBefore, "hi")
        XCTAssertEqual(event.textAfter, "hi!")
        XCTAssertEqual(event.replacementString, "!")
        XCTAssertEqual(event.rangeStart, 2)
        XCTAssertEqual(event.rangeLength, 0)
        XCTAssertEqual(event.eventType, .insert)
        // System-keyboard limitation: no per-key tap info is available.
        XCTAssertEqual(event.keyLabel, "")
        XCTAssertEqual(event.tapLocalX, 0)
        XCTAssertEqual(event.tapLocalY, 0)
        XCTAssertEqual(event.expectedChar, "")
        XCTAssertEqual(manager.liveTypedText, "hi!")
    }

    // MARK: - Edge case 2: End Early race with timer expiry (no double-finalize)

    func testFinalizeFreeWriting_doesNotDoubleFinalize() {
        let manager = makeManager()
        manager.startFreeWriting(participant: makeParticipant())
        manager.captureFreeWritingEvent(
            textBefore: "", textAfter: "a", replacementString: "a",
            rangeStart: 0, rangeLength: 0, eventType: .insert
        )

        manager.finalizeFreeWriting(finalText: "first end")
        XCTAssertFalse(manager.isFreeWritingActive)
        XCTAssertTrue(manager.isFreeWritingComplete)
        XCTAssertEqual(manager.currentTrial?.finalText, "first end")

        // Simulate "End Early" tapped right as the timer also hits 0.
        manager.finalizeFreeWriting(finalText: "second end (should be ignored)")
        XCTAssertEqual(manager.currentTrial?.finalText, "first end",
                        "second finalize call must be a no-op (guarded by isFreeWritingActive)")
    }

    // MARK: - Edge case 1: no keystrokes typed — End Early always works

    func testFinalizeFreeWriting_withZeroKeystrokes_stillCompletesSuccessfully() {
        let manager = makeManager()
        manager.startFreeWriting(participant: makeParticipant())

        // No captureFreeWritingEvent call at all — timer never started.
        manager.finalizeFreeWriting(finalText: "")

        XCTAssertFalse(manager.isFreeWritingActive)
        XCTAssertTrue(manager.isFreeWritingComplete, "End Early must always be able to finalize, even with 0 keystrokes")
    }

    // MARK: - Edge case 3: Cancel from start screen

    func testResetFreeWriting_afterCancelFromStartScreen_leavesNoDanglingState() {
        let manager = makeManager()
        manager.startFreeWriting(participant: makeParticipant())
        XCTAssertTrue(manager.isFreeWritingActive)

        // Simulate tapping "Cancel" before typing begins.
        manager.resetFreeWriting()

        XCTAssertFalse(manager.isFreeWritingActive)
        XCTAssertFalse(manager.isFreeWritingComplete)
        XCTAssertNil(manager.currentSession)
        XCTAssertNil(manager.currentTrial)
        XCTAssertEqual(manager.freeWritingPrompt, "")
        XCTAssertTrue(manager.freeWritingEvents.isEmpty)
        XCTAssertEqual(manager.remainingSeconds, 0)
    }

    // MARK: - Tester focus #5: study/trial isolation — failure/no-op case

    func testFinalizeFreeWriting_isNoOpWhenFreeWritingWasNeverStarted() {
        let manager = makeManager()
        // A normal timed-study SessionManager never sets isFreeWritingActive.
        XCTAssertFalse(manager.isFreeWritingActive)

        manager.finalizeFreeWriting(finalText: "should not run")

        XCTAssertFalse(manager.isFreeWritingComplete, "must remain untouched when free writing was never active")
        XCTAssertNil(manager.currentSession)
        XCTAssertNil(manager.currentTrial)
    }
}
