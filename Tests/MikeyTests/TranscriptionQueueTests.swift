import Foundation
import Testing
@testable import Mikey

/// Issue #7 "Transcription queue": `Transcribe All Pending` drains the
/// backlog serially, oldest first, publishing "job N of M" for the menu; a
/// failed job is reported and stays pending without stopping the rest, a
/// declined model-download prompt stops the run, and recording keeps working
/// while the queue runs (SPEC §2, §6).
@MainActor
struct TranscriptionQueueTests {
    private let tempDir: URL
    private let archive: Archive
    private let engine: FakeRecordingEngine
    private let notifier: FakeNotifier
    private let transcriber: FakeTranscriber
    private let consent: FakeModelDownloadConsent
    private let appState: AppState

    /// The recording tests' Session start — kept clear of the hand-written
    /// pending filenames so a mid-queue Session never collides with one.
    private static var sessionStart: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 20
        components.hour = 14; components.minute = 0
        return Calendar.current.date(from: components)!
    }

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        archive = Archive(root: tempDir)
        engine = FakeRecordingEngine()
        notifier = FakeNotifier()
        transcriber = FakeTranscriber()
        consent = FakeModelDownloadConsent()
        appState = AppState(
            sessions: SessionController(
                engine: engine,
                archive: archive,
                clock: FixedClock(now: Self.sessionStart),
                notifier: notifier
            ),
            transcription: TranscriptionController(
                transcriber: transcriber,
                consent: consent,
                notifier: notifier
            )
        )
        // Lays out the course folders before tests drop files into them.
        appState.reloadConfig()
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Drops a Recording into a course folder and returns it as a
    /// PendingSession — the queue's input comes from the filesystem scan, so
    /// the test writes the `.m4a` straight into the Archive.
    private func makePending(
        _ name: String,
        in folder: String = "CHEM-101"
    ) throws -> PendingSession {
        let url = tempDir.appending(path: "\(folder)/\(name)")
        try Data([0x00]).write(to: url)
        appState.refreshPending()
        let wanted = url.standardizedFileURL.path
        return try #require(
            appState.pendingSessions.first {
                $0.audioURL.standardizedFileURL.path == wanted
            }
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Arms `holdOpen` so job N blocks until `gate.released >= N` — lets a
    /// test poke at AppState mid-queue, then release jobs one at a time.
    private func holdEachJob(on gate: ReleaseGate) {
        transcriber.holdOpen = { _ in
            while gate.released < transcriber.transcribeCalls {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    // MARK: - Draining order

    @Test func queueDrainsPendingOldestFirst() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        // Written out of order — the queue must sort them by Session start.
        let newest = try makePending("2026-09-17_10-30.m4a")
        let oldest = try makePending("2026-09-15_10-30.m4a", in: "MATH-240")
        let middle = try makePending("2026-09-16_10-30.m4a")

        await appState.transcribeAllPending()

        #expect(
            transcriber.transcribedURLs
                == [oldest, middle, newest].map(\.audioURL)
        )
        // Every completed Session dropped out of pending on its scan.
        #expect(appState.pendingSessions.isEmpty)
        #expect(appState.transcriptionState == .idle)
        #expect(appState.transcriptionQueue == nil)
        #expect(appState.lastError == nil)
        #expect(notifier.posted.count == 3)
    }

    @Test func queueProgressReportsActiveJobOutOfTotal() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        let oldest = try makePending("2026-09-15_10-30.m4a")
        _ = try makePending("2026-09-16_10-30.m4a")
        _ = try makePending("2026-09-17_10-30.m4a")
        let gate = ReleaseGate()
        holdEachJob(on: gate)

        let run = Task { await appState.transcribeAllPending() }

        #expect(await waitUntil { transcriber.transcribeCalls == 1 })
        #expect(appState.transcriptionQueue == AppState.QueueProgress(active: 1, total: 3))
        #expect(appState.transcriptionState == .transcribing(oldest, progress: 0))

        gate.released = 1
        #expect(await waitUntil { transcriber.transcribeCalls == 2 })
        #expect(appState.transcriptionQueue == AppState.QueueProgress(active: 2, total: 3))
        // Job 1's `.md` landed and its refreshPending already shrank the list.
        #expect(appState.pendingSessions.count == 2)

        gate.released = 3
        await run.value
        #expect(appState.transcriptionQueue == nil)
        #expect(appState.pendingSessions.isEmpty)
    }

    // MARK: - Failure isolation & retry

    @Test func failedJobStaysPendingAndQueueMovesOn() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        let first = try makePending("2026-09-15_10-30.m4a")
        let failing = try makePending("2026-09-16_10-30.m4a")
        let last = try makePending("2026-09-17_10-30.m4a")
        transcriber.errorForFile = { url in
            url == failing.audioURL ? CancellationError() : nil
        }

        await appState.transcribeAllPending()

        // The failure was reported and left pending; the rest still ran.
        #expect(transcriber.transcribeCalls == 3)
        #expect(transcriber.transcribedURLs.last == last.audioURL)
        #expect(appState.pendingSessions == [failing])
        #expect(appState.lastError != nil)
        #expect(appState.transcriptionQueue == nil)
        #expect(exists(first.transcriptURL))
        #expect(exists(last.transcriptURL))
        #expect(!exists(failing.transcriptURL))
    }

    @Test func retriggerAfterFailureCompletesCleanly() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        let failing = try makePending("2026-09-15_10-30.m4a")
        _ = try makePending("2026-09-16_10-30.m4a")
        transcriber.errorForFile = { url in
            url == failing.audioURL ? CancellationError() : nil
        }

        await appState.transcribeAllPending()
        #expect(appState.pendingSessions == [failing])

        // Same shape as a relaunch after an interrupted run: the Session is
        // still pending and the next trigger re-runs it (SPEC §6).
        transcriber.errorForFile = nil
        await appState.transcribeAllPending()

        #expect(exists(failing.transcriptURL))
        #expect(appState.pendingSessions.isEmpty)
        #expect(appState.transcriptionQueue == nil)
    }

    // MARK: - Serialization

    @Test func tapsWhileQueueRunsAreNoOps() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        _ = try makePending("2026-09-15_10-30.m4a")
        _ = try makePending("2026-09-16_10-30.m4a")
        let gate = ReleaseGate()
        holdEachJob(on: gate)
        let run = Task { await appState.transcribeAllPending() }
        #expect(await waitUntil { transcriber.transcribeCalls == 1 })

        // A second "Transcribe All" and a single-Session Transcribe both hit
        // the one-job-at-a-time guard.
        await appState.transcribeAllPending()
        await appState.transcribe(appState.pendingSessions[0])
        #expect(transcriber.transcribeCalls == 1)
        // …and neither disturbed the running queue's progress.
        #expect(appState.transcriptionQueue == AppState.QueueProgress(active: 1, total: 2))

        gate.released = 2
        await run.value
        #expect(transcriber.transcribeCalls == 2)
        #expect(appState.pendingSessions.isEmpty)
    }

    // MARK: - Recording alongside the queue

    @Test func recordingWorksWhileQueueRuns() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        _ = try makePending("2026-09-15_10-30.m4a")
        let gate = ReleaseGate()
        holdEachJob(on: gate)
        let run = Task { await appState.transcribeAllPending() }
        #expect(await waitUntil { transcriber.transcribeCalls == 1 })

        // A Session starts and stops normally mid-queue.
        await appState.recordCourse(appState.courseFolders[0])
        guard case .recording = appState.recordingState else {
            Issue.record("recording must start while the queue runs")
            gate.released = .max
            return
        }
        appState.stopRecording()
        #expect(appState.recordingState == .idle)

        gate.released = .max
        await run.value

        // The new Recording landed after the snapshot, so the queue left it
        // alone — it's the one pending Session now.
        #expect(transcriber.transcribeCalls == 1)
        #expect(await waitUntil { appState.pendingSessions.count == 1 })
        #expect(appState.pendingSessions[0].courseLabel == "CHEM 101")
    }

    // MARK: - Model-download consent

    @Test func declinedDownloadConsentStopsTheQueue() async throws {
        defer { cleanup() }
        transcriber.modelReady = false
        consent.grant = false
        _ = try makePending("2026-09-15_10-30.m4a")
        _ = try makePending("2026-09-16_10-30.m4a")

        await appState.transcribeAllPending()

        // One prompt covers the whole run — a "no" doesn't re-ask per file.
        #expect(consent.prompts.count == 1)
        #expect(transcriber.transcribeCalls == 0)
        #expect(appState.pendingSessions.count == 2)
        #expect(appState.transcriptionQueue == nil)
        // A decline isn't a failure — nothing lands in `lastError`.
        #expect(appState.lastError == nil)
    }

    @Test func grantedConsentCoversTheWholeQueue() async throws {
        defer { cleanup() }
        transcriber.modelReady = false
        // The first job's download makes the model ready for the rest, the
        // way the real transcriber behaves once the model is on disk.
        transcriber.holdOpen = { _ in transcriber.modelReady = true }
        _ = try makePending("2026-09-15_10-30.m4a")
        _ = try makePending("2026-09-16_10-30.m4a")

        await appState.transcribeAllPending()

        #expect(consent.prompts == ["large-v3-turbo"])
        #expect(transcriber.transcribeCalls == 2)
        #expect(appState.pendingSessions.isEmpty)
    }

    // MARK: - Mid-queue changes

    @Test func jobWhoseTranscriptLandsMidQueueIsSkipped() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        _ = try makePending("2026-09-15_10-30.m4a")
        let second = try makePending("2026-09-16_10-30.m4a")
        // While job 1 runs, a `.md` appears next to job 2's Recording (filed
        // by hand, or another run beat us to it) — the job must be skipped.
        let gate = ReleaseGate()
        transcriber.holdOpen = { _ in
            try? Data("filed by hand".utf8).write(to: second.transcriptURL)
            while gate.released < 1 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        let run = Task { await appState.transcribeAllPending() }
        #expect(await waitUntil { transcriber.transcribeCalls == 1 })
        gate.released = 1
        await run.value

        #expect(transcriber.transcribeCalls == 1)
        #expect(appState.pendingSessions.isEmpty)
        #expect(appState.lastError == nil)
    }
}

/// Counts how many held-open jobs may proceed: job N waits while
/// `released < N`.
private final class ReleaseGate {
    var released = 0
}

/// Waits briefly for an async condition — queue jobs hop through Tasks and
/// fakes, same helper as in PendingMenuTests.
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
