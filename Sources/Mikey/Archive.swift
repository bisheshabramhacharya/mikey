import Foundation

/// The folder-based "brain" holding all Sessions' Recordings
/// (`~/Documents/Mikey` by default). The filesystem is the source of truth —
/// there is no database.
public struct Archive: Sendable {
    public let root: URL

    public init(root: URL = Archive.defaultRoot()) {
        self.root = root
    }

    /// (No `.isDirectory` hint — it would bake a trailing "/" into the URL's
    /// path, so the root wouldn't string-compare equal to `~/Documents/Mikey`.)
    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/Mikey")
    }

    /// `<Archive>/config.json` — the user-editable configuration (SPEC §5).
    public var configFileURL: URL {
        root.appending(path: "config.json")
    }

    /// Where Quick Record Sessions are filed.
    public var unsortedFolder: URL {
        root.appending(path: "Unsorted", directoryHint: .isDirectory)
    }

    /// Creates the archive folder (and parents) if needed. Returns the root.
    @discardableResult
    public func createIfNeeded() throws -> URL {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    /// URL for a new Session's Recording inside `folder` (default: `Unsorted/`),
    /// named `YYYY-MM-DD_HH-mm.m4a` from the Session's start time. A same-minute
    /// collision appends `-2`, `-3`, … (SPEC §4).
    public func newSessionURL(at date: Date, in folder: URL? = nil) throws -> URL {
        let folder = folder ?? unsortedFolder
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let base = Self.sessionNameFormatter.string(from: date)
        var candidate = folder.appending(path: "\(base).m4a")
        var suffix = 2
        // Also skip stems still claimed by a live capture (`.caf`) or a
        // leftover `.recording` marker — reusing one would overwrite audio a
        // crashed Session left behind for recovery.
        func stemClaimed(_ audio: URL) -> Bool {
            let fileManager = FileManager.default
            return fileManager.fileExists(atPath: audio.path(percentEncoded: false))
                || fileManager.fileExists(
                    atPath: CaptureFile.url(for: audio).path(percentEncoded: false))
                || fileManager.fileExists(
                    atPath: RecordingMarker.url(for: audio).path(percentEncoded: false))
        }
        while stemClaimed(candidate) {
            candidate = folder.appending(path: "\(base)-\(suffix).m4a")
            suffix += 1
        }
        return candidate
    }

    /// Course name → Archive folder name: "CHEM 101" → "CHEM-101". Runs of
    /// non-alphanumerics collapse to single dashes; the result is uppercased.
    /// A name with no usable characters falls back to "COURSE" (SPEC §4).
    public static func slugify(_ course: String) -> String {
        let slug = course
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .uppercased()
        return slug.isEmpty ? "COURSE" : slug
    }

    /// Resolves each configured Course to its Archive folder, in config order.
    /// Two Courses slugifying to the same name are disambiguated with a
    /// deterministic `-2`, `-3`, … suffix; `Unsorted` is reserved for Quick
    /// Record, so a Course colliding with it is bumped the same way.
    /// Comparison is lowercased because APFS is case-insensitive by default.
    public func courseFolders(for courses: [String]) -> [CourseFolder] {
        var used: Set<String> = [unsortedFolder.lastPathComponent.lowercased()]
        return courses.map { name in
            let slug = Self.slugify(name)
            var candidate = slug
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(slug)-\(suffix)"
                suffix += 1
            }
            used.insert(candidate.lowercased())
            return CourseFolder(
                name: name,
                folder: root.appending(path: candidate, directoryHint: .isDirectory)
            )
        }
    }

    /// Creates the Archive layout: the root, one folder per Course, and
    /// `Unsorted/`. Only ever adds — folders and Recordings for Courses
    /// removed from the config are left untouched (SPEC §7).
    public func ensureLayout(courses: [String]) throws {
        try createIfNeeded()
        for course in courseFolders(for: courses) {
            try FileManager.default.createDirectory(
                at: course.folder,
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: unsortedFolder,
            withIntermediateDirectories: true
        )
    }

    private static let sessionNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()
}

/// A configured Course name paired with the Archive folder its Sessions file
/// into. `name` is what the menu shows; `folder` is the resolved,
/// collision-free `Archive/<slug>`.
public struct CourseFolder: Equatable, Sendable, Identifiable {
    public let name: String
    public let folder: URL

    public var id: URL { folder }

    public init(name: String, folder: URL) {
        self.name = name
        self.folder = folder
    }
}
