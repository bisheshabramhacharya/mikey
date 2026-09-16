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

    /// A fix-it action the menu can offer next to `lastError` when a failure
    /// has a user remedy.
    public enum ErrorFix {
        /// Deep-link to System Settings → Privacy → Microphone.
        case openMicrophoneSettings
    }

    /// What the background transcription job is doing, for the menu's
    /// progress line (SPEC §2). At most one job runs at a time.
    public enum TranscriptionState: Equatable {
        case idle
        case downloadingModel(progress: Double)
        case loadingModel
        case transcribing(PendingSession, progress: Double)
    }

    /// Where a `Transcribe All Pending` run stands — `active` is the job
    /// number in flight (1-based) out of the `total` snapshotted when the
    /// run started. Rendered as "job N of M" in the menu (SPEC §2).
    public struct QueueProgress: Equatable, Sendable {
        public var active: Int
        public var total: Int

        public init(active: Int, total: Int) {
            self.active = active
            self.total = total
        }
    }

    public private(set) var recordingState: RecordingState = .idle
    /// Human-readable failure shown in the menu (permission denied, no input
    /// device, …). Cleared on the next attempt.
    public private(set) var lastError: String?
    /// The remedy button rendered beside `lastError`, if any.
    public private(set) var errorFix: ErrorFix?
    /// `.m4a` files recovered at launch from a Session that died mid-capture
    /// (crash / force-quit). Surfaced once in the menu, cleared on the next
    /// recording attempt.
    public private(set) var recoveredFiles: [URL] = []
    /// Latest `config.json` load — refreshed every time the menu opens.
    public private(set) var configState: ConfigStore.State = .ok(.standard)
    /// Courses resolved to Archive folders, in config order. Empty while the
    /// config is corrupt — Quick Record then stays the only record action.
    public private(set) var courseFolders: [CourseFolder] = []
    /// Pending Sessions — `.m4a` with no sibling `.md` — newest first.
    /// Re-derived from the Archive on every menu open (no stored state).
    public private(set) var pendingSessions: [PendingSession] = []
    public private(set) var transcriptionState: TranscriptionState = .idle
    /// Where a `Transcribe All Pending` run stands, for the menu's
    /// "job N of M" line. `nil` when no queue is running; a single
    /// `transcribe(_:)` doesn't set it.
    public private(set) var transcriptionQueue: QueueProgress?

    /// Seconds of audio captured so far. Refreshed by the ticker while
    /// recording — the engine's live value isn't Observable, so the views read
    /// this snapshot (SPEC §2: elapsed `mm:ss` in the menu bar).
    public private(set) var elapsedTime: TimeInterval = 0
    /// Latest mic RMS level (0…1), refreshed on the same tick — drives the
    /// menu's input-level meter.
    public private(set) var inputLevel: Float = 0
    /// Toggles every tick while recording; the menu-bar indicator's opacity
    /// follows it, producing the pulse animation from the one shared ticker.
    public private(set) var recordingPulse = false

    /// How often the ticker republishes elapsed/level/pulse — fast enough for
    /// a live meter, cheap enough to run for a 75-minute lecture.
    private static let recordingTickInterval: TimeInterval = 0.2

    private let sessions: SessionController
    private let configStore: ConfigStore
    private let sessionStore: SessionStore
    private let transcription: TranscriptionController
    private let ticker: any Ticker
    private let quitFlow: any QuitFlow
    /// Token identifying the running job so late progress hops from a finished
    /// job can't overwrite the state after it resets (SPEC §6).
    private var transcriptionJob: URL?

    public init(
        sessions: SessionController = SessionController(),
        configStore: ConfigStore? = nil,
        sessionStore: SessionStore? = nil,
        transcription: TranscriptionController? = nil,
        ticker: any Ticker = TimerTicker(),
        quitFlow: any QuitFlow = AppQuitFlow()
    ) {
        self.sessions = sessions
        self.configStore = configStore ?? ConfigStore(archive: sessions.archive)
        self.sessionStore = sessionStore ?? SessionStore(archive: sessions.archive)
        self.transcription = transcription ?? TranscriptionController()
        self.ticker = ticker
        self.quitFlow = quitFlow
        sessions.onSessionInterrupted = { [weak self] session in
            guard let self,
                  case .recording(let current) = self.recordingState,
                  current == session else { return }
            // The controller finalizes the file itself — we just leave the
            // recording UI state and stop the ticker.
            self.ticker.stop()
            self.recordingState = .idle
            self.elapsedTime = 0
            self.inputLevel = 0
            self.recordingPulse = false
        }
        // First launch: write `config.json` + lay out the Archive before the
        // menu is ever opened (SPEC §5).
        reloadConfig()
        // Recovery transcodes leftover `.caf` captures — real work, so it
        // runs off the init path and lands here when done.
        Task { [weak self] in
            let recovered = await sessions.recoverInterruptedSessions()
            self?.recoveredFiles = recovered
        }
    }

    public var archiveURL: URL { sessions.archiveURL }

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
        await startRecording { try await $0.startSession() }
    }

    /// Menu action: `▶ <Course>`. Starts a Session filed under that Course's
    /// folder in the Archive.
    public func recordCourse(_ course: CourseFolder) async {
        await startRecording { try await $0.startSession(course: course) }
    }

    /// Shared record path: every entry — course or Quick Record — gets the
    /// ticker, the UI snapshot reset, and the auto-stop enforcement.
    private func startRecording(
        _ start: (SessionController) async throws -> Session
    ) async {
        guard recordingState == .idle else { return }
        lastError = nil
        errorFix = nil
        recoveredFiles = []
        do {
            let session = try await start(sessions)
            elapsedTime = 0
            inputLevel = 0
            recordingPulse = false
            recordingState = .recording(session)
            ticker.start(every: Self.recordingTickInterval) { [weak self] in
                self?.handleTick()
            }
        } catch {
            lastError = error.localizedDescription
            if let failure = error as? SessionController.Failure,
               case .microphoneAccessDenied = failure {
                errorFix = .openMicrophoneSettings
            }
        }
    }

    /// Menu action: `■ Stop Recording`. Ends capture immediately, then
    /// finalizes the `.m4a` in the background (transcode of the `.caf`).
    public func stopRecording() {
        guard case .recording(let session) = recordingState else { return }
        finishRecording(session, reason: .manual)
    }

    /// Menu action: `Transcribe` on a pending Session. One job at a time —
    /// a second tap while a job runs is a no-op (the menu also disables the
    /// buttons). A decline on the model-download prompt leaves everything as
    /// it was; a failure lands in `lastError` with the Session still pending.
    public func transcribe(_ session: PendingSession) async {
        _ = await runTranscriptionJob(session)
    }

    /// Menu action: `Transcribe All Pending`. Drains the pending backlog
    /// serially, oldest first, through the same one-job path — a tap while a
    /// job runs is a no-op (SPEC §6).
    ///
    /// The set is snapshotted at tap time: a Recording that lands mid-queue
    /// waits for the next trigger, and each job re-checks its Transcript is
    /// still missing before running, so a re-triggered run picks up exactly
    /// where an interrupted one left off. A thrown job is reported in
    /// `lastError`, stays pending, and the queue moves on. A declined
    /// model-download prompt stops the whole run — every job left needs the
    /// same download, so re-prompting per file would just nag.
    public func transcribeAllPending() async {
        guard transcriptionState == .idle else { return }
        defer { transcriptionQueue = nil }
        let queue = pendingSessions.sorted { $0.startedAt < $1.startedAt }
        for (index, session) in queue.enumerated() {
            transcriptionQueue = QueueProgress(active: index + 1, total: queue.count)
            guard !FileManager.default.fileExists(
                atPath: session.transcriptURL.path(percentEncoded: false)
            ) else { continue }
            switch await runTranscriptionJob(session) {
            case .declined?:
                return
            default:
                continue
            }
        }
    }

    /// The one-job path shared by `transcribe(_:)` and the queue: the
    /// serialization guard, the `transcriptionJob` token, progress hops, and
    /// the error → `lastError` mapping. Returns the job's outcome — `nil` on
    /// a throw — so the queue can tell a declined download prompt from a
    /// failure it should move past.
    private func runTranscriptionJob(
        _ session: PendingSession
    ) async -> TranscriptionController.Outcome? {
        guard transcriptionState == .idle else { return nil }
        transcriptionJob = session.audioURL
        transcriptionState = .transcribing(session, progress: 0)
        defer {
            transcriptionJob = nil
            transcriptionState = .idle
            refreshPending()
        }
        do {
            return try await transcription.transcribe(
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
            return nil
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

    /// Menu action shown when mic permission is denied — deep-links to
    /// System Settings → Privacy → Microphone (SPEC §7).
    public func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Menu action: `Quit Mikey`. Quitting mid-Session warns first (SPEC §7):
    /// confirm runs the normal finalize path (async — the `.caf` transcode
    /// must finish before terminate), cancel keeps recording.
    public func quit() {
        guard case .recording(let session) = recordingState else {
            quitFlow.terminateNow()
            return
        }
        guard quitFlow.confirmQuitWhileRecording() else { return }
        ticker.stop()
        recordingState = .idle
        elapsedTime = 0
        inputLevel = 0
        recordingPulse = false
        Task {
            await sessions.stopSession(session, reason: .manual)
            quitFlow.terminateNow()
        }
    }

    /// One ticker heartbeat: republish the live snapshot the views observe,
    /// flip the pulse, and enforce the Session cap. Auto-stop funnels through
    /// the exact same finalize path as a manual stop.
    private func handleTick() {
        guard case .recording(let session) = recordingState else { return }
        elapsedTime = sessions.elapsedTime
        inputLevel = sessions.inputLevel
        recordingPulse.toggle()
        if sessions.hasReachedAutoStopLimit {
            finishRecording(session, reason: .autoStop)
        }
    }

    /// The single clean-stop path every exit takes — manual stop, auto-stop at
    /// the cap: halt the ticker, reset the UI snapshot, then `stopSession`
    /// stops capture + releases the sleep assertion + finalizes the `.m4a`
    /// (async — the `.caf` transcode is real work).
    private func finishRecording(
        _ session: Session,
        reason: SessionController.StopReason
    ) {
        ticker.stop()
        recordingState = .idle
        elapsedTime = 0
        inputLevel = 0
        recordingPulse = false
        Task {
            await sessions.stopSession(session, reason: reason)
            // The finalized `.m4a` is now pending a Transcript.
            refreshPending()
        }
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
