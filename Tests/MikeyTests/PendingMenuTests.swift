import Foundation
import Testing
@testable import Mikey

/// The menu surface for pending Sessions (SPEC §2): the list the menu renders,
/// the per-Session `Transcribe` action, and progress state — wired through
/// `AppState` with the transcription backend faked.
@MainActor
struct PendingMenuTests {
    private let tempDir: URL
    private let archive: Archive
    private let engine: FakeRecordingEngine
    private let notifier: FakeNotifier
    private let transcriber: FakeTranscriber
    private let consent: FakeModelDownloadConsent
    private let appState: AppState

    private static var sessionStart: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 15
        components.hour = 10; components.minute = 30
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
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Stops a recording and waits for the async finalize — the fake engine
    /// writes a real `.caf` on stop, the transcode lands the `.m4a`, and the
    /// controller's post-finalize `refreshPending` makes it visible.
    private func finishRecording() async throws {
        appState.stopRecording()
        let sawPending = await waitUntil { !appState.pendingSessions.isEmpty }
        try #require(sawPending)
    }

    @Test func stoppedSessionAppearsPending() async throws {
        defer { cleanup() }
        appState.reloadConfig()
        await appState.recordCourse(appState.courseFolders[0])

        try await finishRecording()

        #expect(appState.pendingSessions.count == 1)
        #expect(appState.pendingSessions.first?.menuLabel == "CHEM 101 · 2026-09-15 10:30")
    }

    @Test func transcribeClearsPendingAndPostsRevealNotification() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        appState.reloadConfig()
        await appState.recordCourse(appState.courseFolders[0])
        try await finishRecording()
        let session = try #require(appState.pendingSessions.first)

        await appState.transcribe(session)

        #expect(appState.transcriptionState == .idle)
        #expect(appState.lastError == nil)
        #expect(appState.pendingSessions.isEmpty)
        #expect(notifier.posted.last?.title == "Transcript ready — CHEM 101")
        #expect(notifier.revealed.last! == session.transcriptURL)
        #expect(
            FileManager.default.fileExists(
                atPath: session.transcriptURL.path(percentEncoded: false)
            )
        )
    }

    @Test func failedTranscribeSurfacesErrorAndStaysPending() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        transcriber.stubbedError = CancellationError()
        appState.reloadConfig()
        await appState.recordCourse(appState.courseFolders[0])
        try await finishRecording()
        let session = try #require(appState.pendingSessions.first)

        await appState.transcribe(session)

        #expect(appState.transcriptionState == .idle)
        #expect(appState.lastError != nil)
        #expect(appState.pendingSessions.count == 1)
    }
}

/// Waits briefly for an async condition — stop finalizes on a Task (the
/// `.caf` transcode is real work), same helper as in RecordingTrustTests.
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
