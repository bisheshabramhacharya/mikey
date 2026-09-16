import AVFoundation
import Foundation
import Testing
@testable import Mikey

/// Issue #5 end-to-end-ish coverage at the SessionController/AppState seam:
/// disk-space guard, `.recording` marker + `.caf` lifecycle, engine-initiated
/// stop, and launch recovery (transcode of the leftover capture).
@MainActor
struct CrashProofingTests {
    private let tempDir: URL
    private let engine: FakeRecordingEngine
    private let notifier: FakeNotifier
    private let diskSpace: FakeDiskSpaceProbe
    private let controller: SessionController

    private static var sessionStart: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 15
        components.hour = 10; components.minute = 30
        return Calendar.current.date(from: components)!
    }

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        engine = FakeRecordingEngine()
        notifier = FakeNotifier()
        diskSpace = FakeDiskSpaceProbe(available: 10 * 1024 * 1024 * 1024) // 10 GB
        controller = SessionController(
            engine: engine,
            archive: Archive(root: tempDir),
            clock: FixedClock(now: Self.sessionStart),
            notifier: notifier,
            diskSpace: diskSpace
        )
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Seeds the leftovers of a crashed Session: a real (tiny, valid) `.caf`
    /// plus its `.recording` marker.
    private func seedCrashedSession(_ audio: URL) throws {
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writer = try CAFCaptureWriter(url: CaptureFile.url(for: audio))
        let buffer = AVAudioPCMBuffer(
            pcmFormat: writer.format, frameCapacity: 4_096
        )!
        buffer.frameLength = 4_096
        buffer.floatChannelData?[0].update(repeating: 0, count: 4_096)
        try writer.append(buffer)
        writer.finish()
        try RecordingMarker.create(for: audio)
    }

    /// Waits briefly for an async condition (background finalize/recovery).
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

    // MARK: Disk-space guard

    @Test func startRefusedUnder500MBFree() async {
        defer { cleanup() }
        diskSpace.available = 200 * 1024 * 1024

        await #expect {
            try await controller.startSession()
        } throws: { error in
            guard case .insufficientDiskSpace(let free)
                    = error as? SessionController.Failure else { return false }
            return free == 200 * 1024 * 1024
        }
        // Refused before the TCC prompt and before any file is touched.
        #expect(engine.requestAccessCalls == 0)
        #expect(engine.startedURL == nil)
        #expect(!exists(tempDir.appending(path: "Unsorted")))
    }

    @Test func startAllowedAtExactly500MB() async throws {
        defer { cleanup() }
        diskSpace.available = SessionController.minimumFreeSpace
        _ = try await controller.startSession()
        #expect(engine.startedURL != nil)
    }

    @Test func startAllowedWhenCapacityUnreadable() async throws {
        defer { cleanup() }
        diskSpace.available = nil // can't determine → don't block on a guess
        _ = try await controller.startSession()
        #expect(engine.startedURL != nil)
    }

    // MARK: Marker + capture lifecycle

    @Test func markerAndCaptureExistWhileRecordingClearOnStop() async throws {
        defer { cleanup() }
        let session = try await controller.startSession()
        let marker = RecordingMarker.url(for: session.fileURL)
        let capture = CaptureFile.url(for: session.fileURL)
        #expect(exists(marker))
        #expect(exists(capture))

        await controller.stopSession(session)

        #expect(!exists(marker))
        #expect(!exists(capture))
        #expect(exists(session.fileURL)) // the finalized .m4a
    }

    @Test func failedStartLeavesNoMarker() async {
        defer { cleanup() }
        struct Boom: Error {}
        engine.startError = Boom()

        await #expect(throws: SessionController.Failure.self) {
            try await controller.startSession()
        }
        #expect(RecoveryScan.interruptedRecordings(in: tempDir).isEmpty)
    }

    // MARK: Engine-initiated stop (input device lost)

    @Test func engineStoppedFinalizesNotifiesAndReports() async throws {
        defer { cleanup() }
        let session = try await controller.startSession()
        var interrupted: Session?
        controller.onSessionInterrupted = { interrupted = $0 }

        engine.onCaptureStopped?() // what MicRecordingEngine does on device loss

        #expect(await waitUntil { interrupted != nil })
        #expect(interrupted == session)
        #expect(await waitUntil { !self.notifier.posted.isEmpty })
        #expect(notifier.posted.first?.title == "Recording stopped — input device changed")
        // Partial capture still finalized into a real .m4a.
        #expect(exists(session.fileURL))
        #expect(!exists(RecordingMarker.url(for: session.fileURL)))
        #expect(!exists(CaptureFile.url(for: session.fileURL)))
    }

    @Test func engineStoppedWithNoActiveSessionIsHarmless() async {
        defer { cleanup() }
        engine.onCaptureStopped?()
        let settled = await waitUntil(300_000_000) { !self.notifier.posted.isEmpty }
        _ = settled // may or may not fire quickly; assert only no crash
        #expect(notifier.posted.isEmpty)
    }

    @Test func appStateReturnsToIdleWhenCaptureStopsItself() async throws {
        defer { cleanup() }
        let appState = AppState(sessions: controller)
        await appState.quickRecord()
        guard case .recording = appState.recordingState else {
            Issue.record("expected .recording")
            return
        }

        engine.onCaptureStopped?()

        #expect(await waitUntil { appState.recordingState == .idle })
    }

    // MARK: Launch recovery

    @Test func recoveryTranscodesCafClearsMarkerAndNotifies() async throws {
        defer { cleanup() }
        let audio = tempDir.appending(path: "Unsorted/2026-09-14_08-00.m4a")
        try seedCrashedSession(audio)

        let recovered = await controller.recoverInterruptedSessions()

        // Directory enumeration resolves /var → /private/var.
        #expect(recovered.map { $0.resolvingSymlinksInPath() }
            == [audio.resolvingSymlinksInPath()])
        #expect(!exists(RecordingMarker.url(for: audio)))
        #expect(!exists(CaptureFile.url(for: audio)))
        // The recovered .m4a is real audio: decodes as 44.1 kHz mono AAC.
        let decoded = try AVAudioFile(forReading: audio)
        #expect(decoded.fileFormat.sampleRate == 44_100)
        #expect(decoded.fileFormat.channelCount == 1)
        #expect(notifier.posted.first?.title == "Recovered a recording")
        // One-shot: a second scan reports nothing.
        #expect(await controller.recoverInterruptedSessions().isEmpty)
    }

    @Test func markerWithoutCaptureIsClearedSilently() async throws {
        defer { cleanup() }
        let audio = tempDir.appending(path: "Unsorted/2026-09-14_08-00.m4a")
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try RecordingMarker.create(for: audio) // died before first write

        let recovered = await controller.recoverInterruptedSessions()

        #expect(recovered.isEmpty)
        #expect(!exists(RecordingMarker.url(for: audio)))
        #expect(notifier.posted.isEmpty)
    }

    @Test func appStateSurfacesRecoveryNoticeAtInit() async throws {
        defer { cleanup() }
        let audio = tempDir.appending(path: "Unsorted/2026-09-14_08-00.m4a")
        try seedCrashedSession(audio)

        let appState = AppState(sessions: controller)

        #expect(await waitUntil { !appState.recoveredFiles.isEmpty })
        #expect(appState.recoveredFiles.map { $0.resolvingSymlinksInPath() }
            == [audio.resolvingSymlinksInPath()])
    }

    // MARK: Mic-denied fix action

    @Test func micDeniedOffersSettingsDeepLink() async {
        defer { cleanup() }
        engine.accessGranted = false
        let appState = AppState(sessions: controller)

        await appState.quickRecord()

        #expect(appState.lastError != nil)
        #expect(appState.errorFix == .openMicrophoneSettings)
    }

    @Test func nonPermissionFailureOffersNoFix() async {
        defer { cleanup() }
        diskSpace.available = 1 // trigger the disk guard instead
        let appState = AppState(sessions: controller)

        await appState.quickRecord()

        #expect(appState.lastError != nil)
        #expect(appState.errorFix == nil)
    }
}
