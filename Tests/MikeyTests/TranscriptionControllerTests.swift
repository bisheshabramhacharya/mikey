import Foundation
import Testing
import os
@testable import Mikey

/// Job orchestration: consent gate → transcribe → atomic `.md` →
/// "Transcript ready" notification that reveals the file (SPEC §6), with the
/// interruption/idempotency invariants that keep a Session pending.
@MainActor
struct TranscriptionControllerTests {
    private let tempDir: URL
    private let archive: Archive
    private let store: SessionStore
    private let transcriber: FakeTranscriber
    private let consent: FakeModelDownloadConsent
    private let notifier: FakeNotifier
    private let controller: TranscriptionController

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        archive = Archive(root: tempDir)
        store = SessionStore(archive: archive)
        try archive.ensureLayout(courses: ["CHEM 101"])
        transcriber = FakeTranscriber()
        consent = FakeModelDownloadConsent()
        notifier = FakeNotifier()
        controller = TranscriptionController(
            transcriber: transcriber,
            consent: consent,
            notifier: notifier
        )
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Drops a Recording into `CHEM-101/` and returns it as a PendingSession.
    /// `contentsOfDirectory` may resolve the temp root's /private symlink, so
    /// compare standardized paths rather than URLs.
    private func makePending(_ name: String = "2026-09-15_10-30.m4a") throws -> PendingSession {
        let url = tempDir.appending(path: "CHEM-101/\(name)")
        try Data([0x00]).write(to: url)
        let wanted = url.standardizedFileURL.path
        let pending = store.pendingSessions(
            courseFolders: archive.courseFolders(for: ["CHEM 101"])
        )
        return try #require(
            pending.first { $0.audioURL.standardizedFileURL.path == wanted }
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func firstRunAsksConsentThenTranscribes() async throws {
        defer { cleanup() }
        transcriber.modelReady = false
        let session = try makePending()

        let outcome = try await controller.transcribe(session, model: "large-v3-turbo")

        #expect(consent.prompts == ["large-v3-turbo"])
        #expect(transcriber.transcribeCalls == 1)
        guard case .completed(let transcriptURL) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(transcriptURL == session.transcriptURL)
        #expect(exists(session.transcriptURL))
        // The notification names the Course and carries the `.md` to reveal.
        #expect(notifier.posted.first?.title == "Transcript ready — CHEM 101")
        #expect(notifier.revealed.first! == session.transcriptURL)
        // …and the Session is no longer pending on the next scan.
        #expect(store.pendingSessions(courseFolders: []).isEmpty)
    }

    @Test func declinedConsentRunsNothing() async throws {
        defer { cleanup() }
        transcriber.modelReady = false
        consent.grant = false
        let session = try makePending()

        let outcome = try await controller.transcribe(session, model: "large-v3-turbo")

        #expect(outcome == .declined)
        #expect(transcriber.transcribeCalls == 0)
        #expect(!exists(session.transcriptURL))
        #expect(notifier.posted.isEmpty)
        #expect(store.pendingSessions(courseFolders: []).count == 1)
    }

    @Test func downloadedModelSkipsConsent() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        let session = try makePending()

        let outcome = try await controller.transcribe(session, model: "large-v3-turbo")

        #expect(consent.prompts.isEmpty)
        guard case .completed = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
    }

    @Test func writtenMarkdownMatchesSpec() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        let session = try makePending()

        _ = try await controller.transcribe(session, model: "large-v3-turbo")

        let markdown = try String(contentsOf: session.transcriptURL, encoding: .utf8)
        #expect(markdown.hasPrefix("# CHEM 101 — 2026-09-15 10:30\n"))
        #expect(markdown.contains("Duration: 01:15:00 · Model: large-v3-turbo"))
        #expect(markdown.contains("**[00:00]** Hello class"))
        #expect(markdown.contains("**[02:14]** Second point"))
    }

    @Test func failureLeavesNoPartialTranscriptAndRetries() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        transcriber.stubbedError = CancellationError()
        let session = try makePending()

        // Interrupted mid-job (sleep/quit): throws, writes nothing.
        await #expect(throws: CancellationError.self) {
            try await controller.transcribe(session, model: "large-v3-turbo")
        }
        #expect(!exists(session.transcriptURL))
        #expect(!exists(session.transcriptURL.appendingPathExtension("tmp")))
        #expect(notifier.posted.isEmpty)

        // Re-trigger re-runs cleanly — the job is idempotent (SPEC §6).
        transcriber.stubbedError = nil
        let outcome = try await controller.transcribe(session, model: "large-v3-turbo")
        guard case .completed = outcome else {
            Issue.record("expected .completed on retry, got \(outcome)")
            return
        }
        #expect(exists(session.transcriptURL))
    }

    @Test func phasesFlowThroughFromTheTranscriber() async throws {
        defer { cleanup() }
        transcriber.modelReady = true
        transcriber.phasesToReport = [
            .transcribing(fraction: 0.4),
            .transcribing(fraction: 1.0),
        ]
        let session = try makePending()

        let seen = OSAllocatedUnfairLock<[TranscriptionPhase]>(initialState: [])
        _ = try await controller.transcribe(session, model: "large-v3-turbo") { phase in
            seen.withLock { $0.append(phase) }
        }

        #expect(
            seen.withLock { $0 }
                == [.transcribing(fraction: 0.4), .transcribing(fraction: 1.0)]
        )
    }
}
