import AppKit
import Foundation

/// The single object the menu-bar UI renders from. Later tickets hang courses,
/// the Pending list, and transcription progress off this same object.
@MainActor
@Observable
public final class AppState {
    public enum RecordingState: Equatable {
        case idle
        case recording(Session)
    }

    public private(set) var recordingState: RecordingState = .idle
    /// Human-readable failure shown in the menu (permission denied, no input
    /// device, …). Cleared on the next attempt.
    public private(set) var lastError: String?
    /// Latest `config.json` load — refreshed every time the menu opens.
    public private(set) var configState: ConfigStore.State = .ok(.standard)
    /// Courses resolved to Archive folders, in config order. Empty while the
    /// config is corrupt — Quick Record then stays the only record action.
    public private(set) var courseFolders: [CourseFolder] = []

    private let sessions: SessionController
    private let configStore: ConfigStore

    public init(
        sessions: SessionController = SessionController(),
        configStore: ConfigStore? = nil
    ) {
        self.sessions = sessions
        self.configStore = configStore ?? ConfigStore(archive: sessions.archive)
        // First launch: write `config.json` + lay out the Archive before the
        // menu is ever opened (SPEC §5).
        reloadConfig()
    }

    public var archiveURL: URL { sessions.archiveURL }
    public var elapsedTime: TimeInterval { sessions.elapsedTime }
    public var inputLevel: Float { sessions.inputLevel }

    /// Reloads `config.json` and re-resolves the Course list the menu renders.
    /// Called at launch and on every menu open — no file-watcher needed
    /// (SPEC §5). A corrupt file empties the Course list and surfaces a
    /// warning; Quick Record keeps working either way.
    public func reloadConfig() {
        let state = configStore.load()
        configState = state
        guard case .ok(let config) = state else {
            courseFolders = []
            return
        }
        // Best-effort: if a folder can't be created now, the record action
        // surfaces the real error when the Session starts.
        try? sessions.archive.ensureLayout(courses: config.courses)
        courseFolders = sessions.archive.courseFolders(for: config.courses)
    }

    /// Menu action: `▶ Quick Record`. Starts a courseless Session filed under
    /// `Archive/Unsorted/`. Mic permission is requested on first use.
    public func quickRecord() async {
        guard recordingState == .idle else { return }
        lastError = nil
        do {
            let session = try await sessions.startSession()
            recordingState = .recording(session)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Menu action: `▶ <Course>`. Starts a Session filed under that Course's
    /// folder in the Archive.
    public func recordCourse(_ course: CourseFolder) async {
        guard recordingState == .idle else { return }
        lastError = nil
        do {
            let session = try await sessions.startSession(course: course)
            recordingState = .recording(session)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Menu action: `■ Stop Recording`. Finalizes the `.m4a`.
    public func stopRecording() {
        guard case .recording(let session) = recordingState else { return }
        sessions.stopSession(session)
        recordingState = .idle
    }

    /// Menu action: `Open Archive Folder` — reveals the Archive in Finder.
    public func openArchiveFolder() {
        try? sessions.archiveURL.createDirectoryWithIntermediates()
        NSWorkspace.shared.open(sessions.archiveURL)
    }

    /// Menu action: `Edit Courses (config.json)` — opens the config in the
    /// default editor. Also the fix affordance for a corrupt file: a missing
    /// config is recreated with defaults first so there's always a file to
    /// open (a corrupt one is opened as-is for the user to repair).
    public func editConfig() {
        reloadConfig()
        NSWorkspace.shared.open(configStore.fileURL)
    }

    /// Menu action: `Quit Mikey`. Stops a running Session first so the file
    /// finalizes cleanly. (A confirm-before-quit prompt lands with the
    /// trust-polish ticket.)
    public func quit() {
        stopRecording()
        NSApplication.shared.terminate(nil)
    }
}

private extension URL {
    func createDirectoryWithIntermediates() throws {
        try FileManager.default.createDirectory(
            at: self,
            withIntermediateDirectories: true
        )
    }
}
