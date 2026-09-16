import Foundation

/// Renders a Transcript's Markdown and lands it next to its `.m4a` (SPEC §6).
///
/// The write is atomic: text goes to `<session>.md.tmp` first and is renamed
/// onto `<session>.md` — the `.md` only ever appears complete, so a job
/// interrupted anywhere before the rename simply leaves the Session pending
/// (and a stray `.tmp` that the next run overwrites).
public struct TranscriptWriter: Sendable {
    public init() {}

    /// The Transcript document for a finished job:
    ///
    /// ```markdown
    /// # CHEM 101 — 2026-09-15 10:30
    /// Duration: 01:15:00 · Model: large-v3-turbo
    ///
    /// **[00:00]** First transcript segment…
    /// **[02:14]** Next segment…
    /// ```
    public func markdown(
        for session: PendingSession,
        output: TranscriptionOutput
    ) -> String {
        var lines = [
            "# \(session.courseLabel) — \(PendingSession.displayDate(session.startedAt))",
            "Duration: \(Self.hoursMinutesSeconds(output.duration)) · Model: \(output.model)",
            "",
        ]
        for segment in output.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("**[\(Self.minutesSeconds(segment.start))]** \(text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `markdown` to `url` atomically via a `.tmp` sibling + rename.
    /// A previous `.md` (or leftover `.tmp`) is replaced.
    public func write(_ markdown: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = url.appendingPathExtension("tmp")
        try Data(markdown.utf8).write(to: tmp)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            // No destination yet (the usual case for a pending Session) —
            // a plain rename is the atomic landing.
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// `h:mm:ss` for the header's Duration field — 75 minutes → `01:15:00`.
    static func hoursMinutesSeconds(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(
            format: "%02d:%02d:%02d",
            total / 3600, (total % 3600) / 60, total % 60
        )
    }

    /// `[mm:ss]` segment timestamps — minutes run past 59 (`[75:30]`), matching
    /// the format in SPEC §6 rather than rolling into hours.
    static func minutesSeconds(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
