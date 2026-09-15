import Foundation
import Testing
@testable import Mikey

/// State-machine coverage: the menu renders `idle` / `recording(Session)` and
/// the record/stop actions drive it through the session controller.
@MainActor
struct AppStateTests {
    private let tempDir: URL
    private let engine: FakeRecordingEngine
    private let notifier: FakeNotifier
    private let appState: AppState

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        engine = FakeRecordingEngine()
        notifier = FakeNotifier()
        appState = AppState(
            sessions: SessionController(
                engine: engine,
                archive: Archive(root: tempDir),
                clock: FixedClock(now: Date()),
                notifier: notifier
            )
        )
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func quickRecordTransitionsIdleToRecording() async throws {
        defer { cleanup() }
        #expect(appState.recordingState == .idle)

        await appState.quickRecord()

        guard case .recording(let session) = appState.recordingState else {
            Issue.record("expected .recording, got \(appState.recordingState)")
            return
        }
        #expect(session.fileURL == engine.startedURL)
        #expect(appState.lastError == nil)
    }

    @Test func stopRecordingTransitionsBackToIdle() async throws {
        defer { cleanup() }
        await appState.quickRecord()
        appState.stopRecording()

        #expect(appState.recordingState == .idle)
        #expect(engine.stopCalls == 1)
        #expect(notifier.posted.count == 1)
    }

    @Test func quickRecordWhileRecordingIsIgnored() async throws {
        defer { cleanup() }
        await appState.quickRecord()
        let first = engine.startedURL

        await appState.quickRecord() // menu can't even show this, but be safe

        #expect(engine.startedURL == first)
        guard case .recording = appState.recordingState else {
            Issue.record("expected still .recording")
            return
        }
    }

    @Test func deniedPermissionStaysIdleWithError() async throws {
        defer { cleanup() }
        engine.accessGranted = false

        await appState.quickRecord()

        #expect(appState.recordingState == .idle)
        #expect(appState.lastError != nil)
    }

    @Test func stopRecordingWhileIdleIsNoOp() {
        appState.stopRecording()
        #expect(appState.recordingState == .idle)
        #expect(engine.stopCalls == 0)
        cleanup()
    }
}
