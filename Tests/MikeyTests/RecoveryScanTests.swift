import Foundation
import Testing
@testable import Mikey

/// `.recording` marker + `.caf` capture lifecycle, and the launch-time scan
/// that turns leftovers into a recovery notice (SPEC §7).
struct RecoveryScanTests {
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// The state a mid-capture crash leaves behind: a `.recording` marker
    /// plus the `.caf` the engine was writing (contents irrelevant to the
    /// scan — it never opens them).
    @discardableResult
    private func seedInterruptedSession(_ audioURL: URL) throws -> InterruptedRecording {
        let marker = RecordingMarker.url(for: audioURL)
        let capture = CaptureFile.url(for: audioURL)
        try FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try RecordingMarker.create(for: audioURL)
        FileManager.default.createFile(
            atPath: capture.path(percentEncoded: false),
            contents: Data("partial audio".utf8)
        )
        return InterruptedRecording(
            audioURL: audioURL, markerURL: marker, captureURL: capture
        )
    }

    @Test func artifactURLsShareTheSessionStem() throws {
        defer { cleanup() }
        let audio = tempDir.appending(path: "Unsorted/2026-09-15_10-30.m4a")
        #expect(
            RecordingMarker.url(for: audio)
                == tempDir.appending(path: "Unsorted/2026-09-15_10-30.recording")
        )
        #expect(
            CaptureFile.url(for: audio)
                == tempDir.appending(path: "Unsorted/2026-09-15_10-30.caf")
        )
        // …and the scan can derive the `.m4a` back from either artifact.
        #expect(RecordingMarker.audioURL(for: RecordingMarker.url(for: audio)) == audio)
        #expect(CaptureFile.audioURL(for: CaptureFile.url(for: audio)) == audio)
    }

    @Test func createThenRemoveMarkerLifecycle() throws {
        defer { cleanup() }
        let audio = tempDir.appending(path: "Unsorted/session.m4a")
        let marker = RecordingMarker.url(for: audio)
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try RecordingMarker.create(for: audio)
        #expect(exists(marker))

        RecordingMarker.remove(for: audio)
        #expect(!exists(marker))
        RecordingMarker.remove(for: audio) // already gone — must not throw
    }

    @Test func scanFindsInterruptedSessionsPerFolder() throws {
        defer { cleanup() }
        // Per-folder design: Unsorted/ today, Course folders once #3 lands.
        let a = tempDir.appending(path: "Unsorted/2026-09-15_10-30.m4a")
        let b = tempDir.appending(path: "CHEM-101/2026-09-16_14-00.m4a")
        try seedInterruptedSession(a)
        try seedInterruptedSession(b)

        // Sorted by filename; directory enumeration resolves /var →
        // /private/var, so compare relative paths not raw URLs.
        let found = RecoveryScan.interruptedRecordings(in: tempDir)
        #expect(found.map {
            $0.audioURL.deletingLastPathComponent().lastPathComponent
                + "/" + $0.audioURL.lastPathComponent
        } == [
            "Unsorted/2026-09-15_10-30.m4a",
            "CHEM-101/2026-09-16_14-00.m4a",
        ])
        #expect(found.allSatisfy { $0.markerURL != nil && $0.captureURL != nil })
    }

    @Test func scanFindsOrphanedCaptureWithoutMarker() throws {
        defer { cleanup() }
        // Crash in the gap between engine start and marker write: `.caf`
        // with no marker and no `.m4a` is still recoverable.
        let audio = tempDir.appending(path: "Unsorted/2026-09-15_10-30.m4a")
        let capture = CaptureFile.url(for: audio)
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: capture.path(percentEncoded: false), contents: Data()
        )

        let found = RecoveryScan.interruptedRecordings(in: tempDir)
        #expect(found.count == 1)
        #expect(found[0].captureURL?.lastPathComponent == "2026-09-15_10-30.caf")
        #expect(found[0].markerURL == nil)
    }

    @Test func scanIgnoresFinishedSessionsAndStrays() throws {
        defer { cleanup() }
        // Clean stop: `.m4a` present, no marker, no `.caf`.
        let done = tempDir.appending(path: "Unsorted/2026-09-15_10-30.m4a")
        try FileManager.default.createDirectory(
            at: done.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: done.path(percentEncoded: false), contents: Data()
        )
        // A `.caf` beside a finished `.m4a` isn't ours to recover.
        FileManager.default.createFile(
            atPath: CaptureFile.url(for: done).path(percentEncoded: false),
            contents: Data()
        )
        // And a stray non-artifact file is not an interruption.
        FileManager.default.createFile(
            atPath: tempDir.appending(path: "Unsorted/notes.md")
                .path(percentEncoded: false),
            contents: Data()
        )

        #expect(RecoveryScan.interruptedRecordings(in: tempDir).isEmpty)
    }

    @Test func clearMarkerLeavesAudioArtifacts() throws {
        defer { cleanup() }
        let audio = tempDir.appending(path: "Unsorted/2026-09-15_10-30.m4a")
        let interrupted = try seedInterruptedSession(audio)

        let found = RecoveryScan.interruptedRecordings(in: tempDir)
        #expect(found.count == 1)
        RecoveryScan.clearMarker(of: interrupted)

        #expect(!exists(interrupted.markerURL!))
        // The `.caf` is only deleted after a successful finalize — never here.
        #expect(exists(interrupted.captureURL!))
    }

    @Test func scanOnEmptyOrMissingArchiveFindsNothing() {
        defer { cleanup() }
        #expect(RecoveryScan.interruptedRecordings(in: tempDir).isEmpty)
        let missing = tempDir.appending(path: "does-not-exist")
        #expect(RecoveryScan.interruptedRecordings(in: missing).isEmpty)
    }
}
