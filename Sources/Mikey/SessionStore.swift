import Foundation

/// A Session whose Recording exists but whose Transcript does not — an `.m4a`
/// in the Archive with no sibling `.md` (CONTEXT.md "Pending"). The filesystem
/// is the source of truth: there is no pending database, the list is derived
/// by scanning on demand.
public struct PendingSession: Equatable, Sendable, Identifiable {
    /// The Recording's `.m4a` in the Archive.
    public let audioURL: URL
    /// Display name for the owning Course — the configured Course name when
    /// the containing folder resolves to one, `"Unsorted"` for Quick Record
    /// Sessions, or the folder's own name when it no longer maps to a
    /// configured Course (semester change; SPEC §7).
    public let courseLabel: String
    /// Session start, parsed back out of the `YYYY-MM-DD_HH-mm` filename.
    /// Falls back to the file's modification date for names Mikey didn't write.
    public let startedAt: Date

    public var id: URL { audioURL }

    public init(audioURL: URL, courseLabel: String, startedAt: Date) {
        self.audioURL = audioURL
        self.courseLabel = courseLabel
        self.startedAt = startedAt
    }

    /// Where the Transcript will be written — the `.md` sibling of the `.m4a`.
    public var transcriptURL: URL {
        audioURL.deletingPathExtension().appendingPathExtension("md")
    }

    /// `<Course or Unsorted> · <date>` as listed in the menu (SPEC §2).
    public var menuLabel: String {
        "\(courseLabel) · \(Self.displayDate(startedAt))"
    }

    /// `2026-09-15 10:30` — the date form used in the menu and the Transcript
    /// header (SPEC §6).
    public static func displayDate(_ date: Date) -> String {
        Self.displayFormatter.string(from: date)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// Scans the Archive for pending Sessions. Pure filesystem reads — cheap
/// enough to run on every menu open, and never out of sync because nothing is
/// stored (SPEC §4).
public struct SessionStore: Sendable {
    public let archive: Archive

    public init(archive: Archive = Archive()) {
        self.archive = archive
    }

    /// Every `.m4a` in a course-level folder (one level below the root)
    /// without a sibling `.md`, newest first. `courseFolders` is the resolved
    /// config mapping used to recover real Course names; folders that don't
    /// match still list their Sessions under the folder's own name.
    public func pendingSessions(courseFolders: [CourseFolder]) -> [PendingSession] {
        let fm = FileManager.default
        // Resolved Course folder path → configured Course name.
        var namesByPath: [String: String] = [
            archive.unsortedFolder.standardizedFileURL.path: "Unsorted"
        ]
        for course in courseFolders {
            namesByPath[course.folder.standardizedFileURL.path] = course.name
        }

        guard let folders = try? fm.contentsOfDirectory(
            at: archive.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var pending: [PendingSession] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(
                      at: folder,
                      includingPropertiesForKeys: [.contentModificationDateKey],
                      options: [.skipsHiddenFiles]
                  )
            else { continue }

            let label = namesByPath[folder.standardizedFileURL.path]
                ?? folder.lastPathComponent
            for file in files where file.pathExtension.lowercased() == "m4a" {
                let transcript = file.deletingPathExtension()
                    .appendingPathExtension("md")
                guard !fm.fileExists(atPath: transcript.path(percentEncoded: false))
                else { continue }
                pending.append(
                    PendingSession(
                        audioURL: file,
                        courseLabel: label,
                        startedAt: Self.sessionDate(for: file)
                    )
                )
            }
        }
        return pending.sorted { $0.startedAt > $1.startedAt }
    }

    /// Recovers the Session start from its `YYYY-MM-DD_HH-mm` (or
    /// `…_HH-mm-N` collision-suffixed) filename. A file Mikey didn't name —
    /// dropped in by hand — falls back to its modification date so it still
    /// sorts sensibly.
    static func sessionDate(for audioURL: URL) -> Date {
        let stem = audioURL.deletingPathExtension().lastPathComponent
        if let parsed = Self.filenameFormatter.date(from: stem) {
            return parsed
        }
        // Retry without a `-2`, `-3`, … collision suffix.
        if let dash = stem.lastIndex(of: "-") {
            let suffix = stem[stem.index(after: dash)...]
            if !suffix.isEmpty,
               suffix.allSatisfy(\.isNumber),
               let parsed = Self.filenameFormatter.date(from: String(stem[..<dash])) {
                return parsed
            }
        }
        let modified = try? audioURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        return modified ?? .distantPast
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()
}
