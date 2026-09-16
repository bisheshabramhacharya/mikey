import Foundation
import Testing
@testable import Mikey

/// Issue #4 "Recording you can trust": the single ticker publishes
/// elapsed/level/pulse into AppState, the cap auto-stops through the normal
/// finalize path, the sleep assertion brackets every Session, and quitting
/// mid-recording confirms first.
///
/// Fakes live here (not in Fakes.swift) so the seams added by this ticket stay
/// with their tests.
@MainActor
struct RecordingTrustTests {
    private let tempDir: URL
    private let engine: FakeRecordingEngine
    private let notifier: FakeNotifier
    private let ticker: FakeTicker
    private let sleepAssertion: FakeSleepAssertion
    private let quitFlow: FakeQuitFlow
    private let sessions: SessionController
    private let appState: AppState

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        engine = FakeRecordingEngine()
        notifier = FakeNotifier()
        ticker = FakeTicker()
        sleepAssertion = FakeSleepAssertion()
        quitFlow = FakeQuitFlow()
        sessions = SessionController(
            engine: engine,
            archive: Archive(root: tempDir),
            clock: FixedClock(now: Date()),
            notifier: notifier,
            sleepAssertion: sleepAssertion
        )
        appState = AppState(sessions: sessions, ticker: ticker, quitFlow: quitFlow)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Ticker: elapsed, level, pulse

    @Test func recordingStartsSingleTicker() async {
        defer { cleanup() }
        await appState.quickRecord()

        #expect(ticker.startCalls == 1)
        #expect(ticker.startedInterval != nil)
    }

    @Test func tickPublishesElapsedAndLevelSnapshot() async {
        defer { cleanup() }
        await appState.quickRecord()
        engine.stubbedElapsed = 95
        engine.stubbedLevel = 0.4

        ticker.fire()

        #expect(appState.elapsedTime == 95)
        #expect(appState.inputLevel == 0.4)
    }

    @Test func tickTogglesMenuBarPulse() async {
        defer { cleanup() }
        await appState.quickRecord()
        #expect(appState.recordingPulse == false)

        ticker.fire()
        #expect(appState.recordingPulse == true)
        ticker.fire()
        #expect(appState.recordingPulse == false)
    }

    @Test func stopRecordingHaltsTickerAndClearsSnapshot() async {
        defer { cleanup() }
        await appState.quickRecord()
        engine.stubbedElapsed = 42
        engine.stubbedLevel = 0.3
        ticker.fire()

        appState.stopRecording()

        #expect(ticker.stopCalls == 1)
        #expect(appState.elapsedTime == 0)
        #expect(appState.inputLevel == 0)
        #expect(appState.recordingPulse == false)
    }

    @Test func failedStartNeverStartsTicker() async {
        defer { cleanup() }
        engine.accessGranted = false

        await appState.quickRecord()

        #expect(ticker.startCalls == 0)
    }

    // MARK: - Auto-stop at the cap

    @Test func autoStopFiresAt75MinuteCap() async {
        defer { cleanup() }
        await appState.quickRecord()
        engine.stubbedElapsed = SessionController.defaultAutoStopLimit

        ticker.fire()

        #expect(appState.recordingState == .idle)
        #expect(ticker.stopCalls == 1)
        // Stop → finalize is async (the `.caf` transcode): wait for it.
        #expect(await waitUntil { engine.stopCalls == 1 })
        #expect(await waitUntil { !notifier.posted.isEmpty })
        #expect(notifier.posted.first?.title == "Recording auto-stopped (75:00)")
    }

    @Test func recordingContinuesJustBelowCap() async {
        defer { cleanup() }
        await appState.quickRecord()
        engine.stubbedElapsed = SessionController.defaultAutoStopLimit - 0.1

        ticker.fire()

        guard case .recording = appState.recordingState else {
            Issue.record("expected still .recording below the cap")
            return
        }
        #expect(engine.stopCalls == 0)
        #expect(notifier.posted.isEmpty)
    }

    @Test func autoStopLimitIsInjectableForConfigSwap() async {
        defer { cleanup() }
        // When config.json lands, `autoStopMinutes` supplies this value — the
        // injection point is the whole mechanism, so prove a custom cap works.
        let custom = SessionController(
            engine: engine,
            archive: Archive(root: tempDir.appending(path: "custom")),
            clock: FixedClock(now: Date()),
            notifier: notifier,
            sleepAssertion: sleepAssertion,
            autoStopLimit: 60
        )
        let state = AppState(sessions: custom, ticker: ticker, quitFlow: quitFlow)
        await state.quickRecord()
        engine.stubbedElapsed = 60

        ticker.fire()

        #expect(await waitUntil { engine.stopCalls == 1 })
        #expect(await waitUntil { !notifier.posted.isEmpty })
        #expect(notifier.posted.first?.title == "Recording auto-stopped (01:00)")
    }

    // MARK: - No idle sleep during a Session

    @Test func sleepAssertionBracketsRecording() async {
        defer { cleanup() }
        #expect(sleepAssertion.isHeld == false)

        await appState.quickRecord()
        #expect(sleepAssertion.beginCalls == 1)
        #expect(sleepAssertion.isHeld == true)

        appState.stopRecording()
        #expect(await waitUntil { sleepAssertion.endCalls == 1 })
        #expect(sleepAssertion.isHeld == false)
    }

    @Test func sleepAssertionReleasedOnAutoStop() async {
        defer { cleanup() }
        await appState.quickRecord()
        engine.stubbedElapsed = SessionController.defaultAutoStopLimit

        ticker.fire()

        #expect(await waitUntil { sleepAssertion.endCalls == 1 })
        #expect(sleepAssertion.isHeld == false)
    }

    @Test func sleepAssertionNeverHeldWhenStartFails() async {
        defer { cleanup() }
        struct Boom: Error {}
        engine.startError = Boom()

        await appState.quickRecord()

        #expect(appState.recordingState == .idle)
        #expect(sleepAssertion.beginCalls == 0)
        #expect(sleepAssertion.isHeld == false)
    }

    // MARK: - Quit while recording

    @Test func quitWhileRecordingConfirmsThenFinalizes() async {
        defer { cleanup() }
        await appState.quickRecord()
        quitFlow.confirmationResult = true

        appState.quit()

        #expect(quitFlow.confirmCalls == 1)
        #expect(appState.recordingState == .idle)
        // Finalize (transcode) then terminate happen on the async stop path.
        #expect(await waitUntil { engine.stopCalls == 1 })
        #expect(await waitUntil { quitFlow.terminateCalls == 1 })
        #expect(sleepAssertion.isHeld == false)
    }

    @Test func quitWhileRecordingCancelKeepsRecording() async {
        defer { cleanup() }
        await appState.quickRecord()
        quitFlow.confirmationResult = false

        appState.quit()

        #expect(quitFlow.confirmCalls == 1)
        guard case .recording = appState.recordingState else {
            Issue.record("cancelled quit must keep recording")
            return
        }
        #expect(engine.stopCalls == 0)
        #expect(sleepAssertion.isHeld == true)
        #expect(quitFlow.terminateCalls == 0)
    }

    @Test func quitWhileIdleTerminatesWithoutConfirming() {
        defer { cleanup() }
        appState.quit()

        #expect(quitFlow.confirmCalls == 0)
        #expect(quitFlow.terminateCalls == 1)
    }
}

/// Waits briefly for an async condition (stop finalizes on a Task — the
/// `.caf` transcode is real work, same helper as in CrashProofingTests).
@MainActor
private func waitUntil(
    _ timeoutNanoseconds: UInt64 = 2_000_000_000,
    _ condition: () -> Bool
) async -> Bool {
    var waited: UInt64 = 0
    while !condition() && waited < timeoutNanoseconds {
        try? await Task.sleep(nanoseconds: 10_000_000)
        waited += 10_000_000
    }
    return condition()
}

/// Manual-fire `Ticker`: tests control exactly when beats land.
private final class FakeTicker: Ticker {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var startedInterval: TimeInterval?
    private var onTick: (@MainActor @Sendable () -> Void)?

    func start(
        every interval: TimeInterval,
        onTick: @escaping @MainActor @Sendable () -> Void
    ) {
        startCalls += 1
        startedInterval = interval
        self.onTick = onTick
    }

    func stop() {
        stopCalls += 1
        onTick = nil
    }

    func fire() {
        onTick?()
    }
}

/// Records begin/end balance; `isHeld` mirrors the real assertion's state.
private final class FakeSleepAssertion: SleepAssertion, @unchecked Sendable {
    private(set) var beginCalls = 0
    private(set) var endCalls = 0
    private(set) var isHeld = false

    func begin() {
        beginCalls += 1
        isHeld = true
    }

    func end() {
        endCalls += 1
        isHeld = false
    }
}

/// Scripted answer to the quit-mid-recording prompt; `terminateNow` only
/// counts (a real terminate would kill the test runner).
private final class FakeQuitFlow: QuitFlow {
    var confirmationResult = true
    private(set) var confirmCalls = 0
    private(set) var terminateCalls = 0

    func confirmQuitWhileRecording() -> Bool {
        confirmCalls += 1
        return confirmationResult
    }

    func terminateNow() {
        terminateCalls += 1
    }
}
