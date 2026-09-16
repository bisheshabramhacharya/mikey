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

    /// What the background transcription job is doing, for the menu's
    /// progress line (SPEC §2). At most one job runs at a time.
    public enum TranscriptionState: Equatable {
        case idle
        case downloadingModel(progress: Double)
        case loadingModel
        case transcribing(PendingSession, progress: Double)
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
    /// Pending Sessions — `.m4a` with no sibling `.md` — newest first.
    /// Re-derived from the Archive on every menu open (no stored state).
    public private(set) var pendingSessions: [PendingSession] = []
    public private(set) var transcriptionState: TranscriptionState = .idle

    private let sessions: SessionController
    private let configStore: ConfigStore
    private let sessionStore: SessionStore
    private let transcription: TranscriptionController
    /// Token identifying the running job so late progress hops from a finished
    /// job can't overwrite the state after it resets (SPEC §6).
    private var transcriptionJob: URL?

    public init(
        sessions: SessionController = SessionController(),
        configStore: ConfigStore? = nil,
        sessionStore: SessionStore? = nil,
        transcription: TranscriptionController? = nil
    ) {
        self.sessions = sessions
        self.configStore = configStore ?? ConfigStore(archive: sessions.archive)
        self.sessionStore = sessionStore ?? SessionStore(archive: sessions.archive)
        self.transcription = transcription ?? TranscriptionController()
        // First launch: write `config.json` + lay out the Archive before the
        // menu is ever opened (SPEC §5).
        reloadConfig()
    }

    public var archiveURL: URL { sessions.archiveURL }
    public var elapsedTime: TimeInterval { sessions.elapsedTime }
    public var inputLevel: Float { sessions.inputLevel }

    /// The `whisperModel` from the last good config load; the standard value
    /// stands in while the config is corrupt (SPEC §5 default).
    private var whisperModel: String {
        if case .ok(let config) = configState { return config.whisperModel }
        return Config.standard.whisperModel
    }

    /// Reloads `config.json` and re-resolves the Course list the menu renders.
    /// Called at launch and on every menu open — no file-watcher needed
    /// (SPEC §5). A corrupt file empties the Course list and surfaces a
    /// warning; Quick Record keeps working either way.
    public func reloadConfig() {
        let state = configStore.load()
        configState = state
        guard case .ok(let config) = state else {
            courseFolders = []
            refreshPending()
            return
        }
        // Best-effort: if a folder can't be created now, the record action
        // surfaces the real error when the Session starts.
        try? sessions.archive.ensureLayout(courses: config.courses)
        courseFolders = sessions.archive.courseFolders(for: config.courses)
        refreshPending()
    }

    /// Re-derives the pending list from the Archive. Called on menu open (via
    /// `reloadConfig`), after a Session stops, and after a job finishes.
    public func refreshPending() {
        pendingSessions = sessionStore.pendingSessions(courseFolders: courseFolders)
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
        // The just-finished Recording is now pending a Transcript.
        refreshPending()
    }

    /// Menu action: `Transcribe` on a pending Session. One job at a time —
    /// a second tap while a job runs is a no-op (the menu also disables the
    /// buttons). A decline on the model-download prompt leaves everything as
    /// it was; a failure lands in `lastError` with the Session still pending.
    public func transcribe(_ session: PendingSession) async {
        guard transcriptionState == .idle else { return }
        transcriptionJob = session.audioURL
        transcriptionState = .transcribing(session, progress: 0)
        defer {
            transcriptionJob = nil
            transcriptionState = .idle
            refreshPending()
        }
        do {
            _ = try await transcription.transcribe(
                session,
                model: whisperModel
            ) { [weak self] phase in
                let job = session.audioURL
                Task { @MainActor [weak self] in
                    guard let self, self.transcriptionJob == job else { return }
                    self.applyPhase(phase, for: session)
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func applyPhase(_ phase: TranscriptionPhase, for session: PendingSession) {
        switch phase {
        case .downloadingModel(let fraction):
            transcriptionState = .downloadingModel(progress: fraction)
        case .loadingModel:
            transcriptionState = .loadingModel
        case .transcribing(let fraction):
            transcriptionState = .transcribing(session, progress: fraction)
        }
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
