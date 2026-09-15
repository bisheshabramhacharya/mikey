import Foundation

/// The folder-based "brain" holding all Sessions' Recordings
/// (`~/Documents/Mikey` by default). The filesystem is the source of truth —
/// there is no database.
public struct Archive: Sendable {
    public let root: URL

    public init(root: URL = Archive.defaultRoot()) {
        self.root = root
    }

    /// Interim archive root; course folders and `config.json` arrive with the
    /// courses ticket. For now every Session is a Quick Record under `Unsorted/`.
    /// (No `.isDirectory` hint — it would bake a trailing "/" into the URL's
    /// path, so the root wouldn't string-compare equal to `~/Documents/Mikey`.)
    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/Mikey")
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
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(base)-\(suffix).m4a")
            suffix += 1
        }
        return candidate
    }

    private static let sessionNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()
}
