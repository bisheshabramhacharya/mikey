import Foundation
import Testing
import os
@testable import Mikey

/// End-to-end WhisperKit verification, opt-in because it performs a real
/// model download (~75 MB for `tiny`). Run with:
///
///     MIKEY_REAL_WHISPER=1 ./Scripts/test.sh --filter realWhisper
///
/// `MIKEY_WHISPER_MODEL` overrides the model (default `tiny`), and
/// `MIKEY_WHISPER_CACHE` can point the model cache at a persistent folder so
/// repeat runs skip the download entirely.
@MainActor
struct WhisperKitSmokeTests {
    nonisolated private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MIKEY_REAL_WHISPER"] != nil
    }

    /// Renders a short spoken `.m4a` with the system `say` synthesizer — real
    /// speech in the same AAC container the recorder writes.
    private func makeSpeech(in dir: URL) throws -> URL {
        let url = dir.appending(path: "Unsorted/2026-09-15_10-30.m4a")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o", url.path(percentEncoded: false),
            "Hello class. Today we discuss the transcription of recorded lectures.",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Issue.record("say failed with status \(process.terminationStatus)")
            return url
        }
        return url
    }

    @Test(.enabled(if: WhisperKitSmokeTests.enabled))
    @MainActor
    func realWhisperTranscribesAShortRecording() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-whisper-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioURL = try makeSpeech(in: tempDir)
        #expect(FileManager.default.fileExists(
            atPath: audioURL.path(percentEncoded: false)
        ))
        let archive = Archive(root: tempDir)
        let store = SessionStore(archive: archive)
        let session = try #require(
            store.pendingSessions(courseFolders: []).first
        )

        let model = ProcessInfo.processInfo.environment["MIKEY_WHISPER_MODEL"] ?? "tiny"
        let modelCache = ProcessInfo.processInfo.environment["MIKEY_WHISPER_CACHE"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? tempDir.appending(path: "Models", directoryHint: .isDirectory)
        let transcriber = WhisperKitTranscriber(downloadBase: modelCache)
        let notifier = FakeNotifier()
        let controller = TranscriptionController(
            transcriber: transcriber,
            consent: FakeModelDownloadConsent(),
            notifier: notifier
        )

        let phases = OSAllocatedUnfairLock<[TranscriptionPhase]>(initialState: [])
        let outcome = try await controller.transcribe(session, model: model) { phase in
            phases.withLock { $0.append(phase) }
        }

        guard case .completed(let transcriptURL) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        print("--- transcript ---\n\(markdown)--- end ---")
        #expect(markdown.contains("# Unsorted — 2026-09-15 10:30"))
        #expect(markdown.contains("Model: \(model)"))
        #expect(markdown.contains("**["))
        #expect(notifier.posted.first?.title == "Transcript ready — Unsorted")
        #expect(phases.withLock { $0 }.contains { $0 == .loadingModel })
    }
}
