import Foundation
import Testing
@testable import Mikey

/// Transcript rendering (SPEC §6 format) and the atomic `.md.tmp` → rename
/// write that keeps an interrupted job from leaving a partial `.md`.
struct TranscriptWriterTests {
    private let writer = TranscriptWriter()
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var session: PendingSession {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 15
        components.hour = 10; components.minute = 30
        return PendingSession(
            audioURL: tempDir.appending(path: "CHEM-101/2026-09-15_10-30.m4a"),
            courseLabel: "CHEM 101",
            startedAt: Calendar.current.date(from: components)!
        )
    }

    @Test func markdownMatchesSpecFormat() {
        let output = TranscriptionOutput(
            segments: [
                TranscriptSegment(start: 0, text: "  First transcript segment…  "),
                TranscriptSegment(start: 134, text: "Next segment…"),
            ],
            duration: 4500,
            model: "large-v3-turbo"
        )

        let markdown = writer.markdown(for: session, output: output)

        #expect(
            markdown == """
                # CHEM 101 — 2026-09-15 10:30
                Duration: 01:15:00 · Model: large-v3-turbo

                **[00:00]** First transcript segment…
                **[02:14]** Next segment…

                """
        )
    }

    @Test func unsortedSessionHeaderUsesUnsortedLabel() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 16
        components.hour = 18; components.minute = 2
        let quick = PendingSession(
            audioURL: tempDir.appending(path: "Unsorted/2026-09-16_18-02.m4a"),
            courseLabel: "Unsorted",
            startedAt: Calendar.current.date(from: components)!
        )
        let output = TranscriptionOutput(
            segments: [TranscriptSegment(start: 61, text: "Hi")],
            duration: 61,
            model: "tiny"
        )

        let markdown = writer.markdown(for: quick, output: output)

        #expect(markdown.hasPrefix("# Unsorted — 2026-09-16 18:02\n"))
        #expect(markdown.contains("Duration: 00:01:01 · Model: tiny"))
        #expect(markdown.contains("**[01:01]** Hi"))
    }

    @Test func emptySegmentsAreSkipped() {
        let output = TranscriptionOutput(
            segments: [
                TranscriptSegment(start: 0, text: "   "),
                TranscriptSegment(start: 5, text: "Real words"),
            ],
            duration: 10,
            model: "tiny"
        )

        let markdown = writer.markdown(for: session, output: output)

        #expect(!markdown.contains("**[00:00]**"))
        #expect(markdown.contains("**[00:05]** Real words"))
    }

    @Test func segmentTimestampsRunMinutesPast59() {
        // A 75-minute lecture's last segment stamps e.g. [74:32] — mm keeps
        // counting, it does not roll into hours (SPEC §6).
        #expect(TranscriptWriter.minutesSeconds(4472) == "74:32")
        #expect(TranscriptWriter.hoursMinutesSeconds(4500) == "01:15:00")
        #expect(TranscriptWriter.hoursMinutesSeconds(61) == "00:01:01")
    }

    @Test func writeLandsMarkdownAtomicallyBesideAudio() throws {
        defer { cleanup() }
        let output = TranscriptionOutput(
            segments: [TranscriptSegment(start: 0, text: "Hello")],
            duration: 3,
            model: "tiny"
        )

        try writer.write(writer.markdown(for: session, output: output), to: session.transcriptURL)

        let written = try String(contentsOf: session.transcriptURL, encoding: .utf8)
        #expect(written.contains("# CHEM 101 — 2026-09-15 10:30"))
        // No temp file is left behind.
        let tmp = session.transcriptURL.appendingPathExtension("tmp")
        #expect(!FileManager.default.fileExists(atPath: tmp.path(percentEncoded: false)))
    }

    @Test func writeOverwritesStaleTmpAndExistingTranscript() throws {
        defer { cleanup() }
        // Orphans from interrupted jobs and a stale .md are all replaced.
        try FileManager.default.createDirectory(
            at: session.transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("half a transcript".utf8)
            .write(to: session.transcriptURL.appendingPathExtension("tmp"))
        try Data("old".utf8).write(to: session.transcriptURL)

        try writer.write("# fresh\n", to: session.transcriptURL)

        #expect(try String(contentsOf: session.transcriptURL, encoding: .utf8) == "# fresh\n")
    }
}
