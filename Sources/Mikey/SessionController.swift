import Foundation

/// A single recorded class meeting. Its Recording is one `.m4a` at `fileURL`
/// — produced by transcoding the crash-safe `.caf` capture once capture ends.
/// `courseName` is the Course it belongs to, or nil for a Quick Record
/// Session filed under `Unsorted/`.
public struct Session: Equatable, Sendable {
    /// Where this Session's Recording lands in the Archive.
    public let fileURL: URL
    public let startedAt: Date
    /// The Course picked in the menu (e.g. "CHEM 101"); nil for Quick Record.
    public let courseName: String?

    public init(fileURL: URL, startedAt: Date, courseName: String? = nil) {
        self.fileURL = fileURL
        self.startedAt = startedAt
        self.courseName = courseName
    }
}

/// Owns the start/stop lifecycle of a Session: permission → Archive URL →
/// engine start on record; engine stop + confirmation notification on stop.
/// Stateless about UI — state lives in `AppState`.
@MainActor
public final class SessionController {
    public enum Failure: LocalizedError {
        case microphoneAccessDenied
        case archiveUnavailable(String)
        case captureFailed(String)
        case insufficientDiskSpace(freeBytes: Int64)

        public var errorDescription: String? {
            switch self {
            case .microphoneAccessDenied:
                "Microphone access is denied — allow Mikey under System Settings → Privacy → Microphone."
            case .archiveUnavailable(let detail):
                "Couldn't prepare the Archive: \(detail)"
            case .captureFailed(let detail):
                "Couldn't start recording: \(detail)"
            case .insufficientDiskSpace(let freeBytes):
                "Not enough free disk space to record — \(freeBytes / (1024 * 1024)) MB free, at least ~500 MB required."
            }
        }
    }

    /// Why a Session ended — drives the confirmation notification text.
    public enum StopReason: Sendable {
        case manual
        /// Hit the `autoStopLimit` cap (SPEC §3).
        case autoStop
    }

    /// A Session never exceeds this length — the CONTEXT invariant, hardcoded
    /// at the SPEC's 75:00. It's an init parameter (not buried in the body) so
    /// the courses/config ticket can swap in `config.json`'s `autoStopMinutes`
    /// as a one-line change at the call site.
    public static let defaultAutoStopLimit: TimeInterval = 75 * 60
    public let autoStopLimit: TimeInterval

    /// Free space required on the Archive's volume to start a Session
    /// (~500 MB, SPEC §7 — a 75-min `.m4a` is ~60–90 MB, so this leaves
    /// generous headroom).
    public static let minimumFreeSpace: Int64 = 500 * 1024 * 1024

    private let engine: any RecordingEngine
    /// The Archive this controller files Sessions into. Exposed so AppState
    /// can resolve Course folders and create the layout from the same root.
    public let archive: Archive
    private let clock: any Clock
    private let notifier: any NotificationPosting
    private let sleepAssertion: any SleepAssertion
    private let diskSpace: any DiskSpaceProbing
    /// The Session currently capturing, so an engine-initiated stop (input
    /// device lost) can be ended properly without the menu's Stop action.
    private var activeSession: Session?

    /// Set by `AppState`: fired when a Session ends without the user pressing
    /// Stop (input device lost mid-capture). Already on the main actor.
    public var onSessionInterrupted: ((Session) -> Void)?

    public init(
        engine: any RecordingEngine = MicRecordingEngine(),
        archive: Archive = Archive(),
        clock: any Clock = SystemClock(),
        notifier: any NotificationPosting = UserNotificationPoster(),
        sleepAssertion: any SleepAssertion = ProcessInfoSleepAssertion(),
        diskSpace: any DiskSpaceProbing = VolumeDiskSpaceProbe(),
        autoStopLimit: TimeInterval = SessionController.defaultAutoStopLimit
    ) {
        self.engine = engine
        self.archive = archive
        self.clock = clock
        self.notifier = notifier
        self.sleepAssertion = sleepAssertion
        self.diskSpace = diskSpace
        self.autoStopLimit = autoStopLimit
        // The engine reports its own stops on the main thread (see
        // MicRecordingEngine's configuration-change observer).
        engine.onCaptureStopped = { [weak self] in
            MainActor.assumeIsolated { self?.captureStoppedByEngine() }
        }
    }

    public var archiveURL: URL { archive.root }
    public var elapsedTime: TimeInterval { engine.elapsedTime }
    public var inputLevel: Float { engine.inputLevel }

    /// True once a live Session reaches `autoStopLimit`. Checked on every tick
    /// so the cap is enforced on captured-audio time, which starts at the first
    /// captured sample (SPEC §3) — not on wall clock.
    public var hasReachedAutoStopLimit: Bool {
        engine.isRecording && engine.elapsedTime >= autoStopLimit
    }

    /// Starts a Session. With a `course` the `.m4a` files under that Course's
    /// folder; with nil it's a Quick Record filed under `Archive/Unsorted/`.
    public func startSession(course: CourseFolder? = nil) async throws -> Session {
        // Disk-space guard runs before the TCC prompt so a refused start
        // never spends the user's one permission dialog.
        do {
            try archive.createIfNeeded()
        } catch {
            throw Failure.archiveUnavailable(error.localizedDescription)
        }
        if let free = diskSpace.availableCapacity(at: archive.root),
           free < Self.minimumFreeSpace {
            throw Failure.insufficientDiskSpace(freeBytes: free)
        }
        guard await engine.requestAccess() else {
            throw Failure.microphoneAccessDenied
        }
        let startedAt = clock.now
        let url: URL
        do {
            url = try archive.newSessionURL(at: startedAt, in: course?.folder)
        } catch {
            throw Failure.archiveUnavailable(error.localizedDescription)
        }
        do {
            // Live audio goes to the crash-safe `.caf` sibling; the `.m4a`
            // exists only once finalized on stop (SPEC §3, §7).
            try engine.start(to: CaptureFile.url(for: url))
        } catch {
            throw Failure.captureFailed(error.localizedDescription)
        }
        // Marker goes down only once capture is live — a failed start leaves
        // no false "died mid-recording" for the next launch to recover. (The
        // `.caf` alone is enough for the recovery scan even if this write
        // fails, so it's non-fatal.)
        try? RecordingMarker.create(for: url)
        // Only after capture is actually running: the Mac may not idle-sleep
        // for the whole Session. Held until `stopSession` — every exit path
        // (manual, auto-stop, quit-confirm) funnels through there.
        sleepAssertion.begin()
        let session = Session(fileURL: url, startedAt: startedAt, courseName: course?.name)
        activeSession = session
        return session
    }

    /// Ends the Session: capture stops, the sleep assertion is released, the
    /// `.caf` is transcoded to the `.m4a`, the `.recording` marker is cleared,
    /// and a notification confirms the stop (SPEC §1/§3). Async because the
    /// transcode is real work.
    public func stopSession(
        _ session: Session,
        reason: StopReason = .manual
    ) async {
        engine.stop()
        sleepAssertion.end()
        if activeSession == session { activeSession = nil }
        // "CHEM 101 — 2026-09-15_10-30.m4a"; Quick Record stays filename-only.
        let detail = [session.courseName, session.fileURL.lastPathComponent]
            .compactMap { $0 }
            .joined(separator: " — ")
        if await finalize(session) {
            switch reason {
            case .manual:
                notifier.post(title: "Recording stopped", body: detail)
            case .autoStop:
                notifier.post(
                    title: "Recording auto-stopped (\(elapsedString(autoStopLimit)))",
                    body: detail
                )
            }
        } else {
            notifier.post(
                title: "Recording stopped — couldn't finish the file",
                body: "\(detail) — will recover on next launch"
            )
        }
    }

    /// Launch-time crash recovery (SPEC §7): a `.recording` marker or a
    /// leftover `.caf` means the previous run died mid-capture. The `.caf`
    /// (playable up to the interruption) is transcoded to the `.m4a`; markers
    /// are cleared so the notice fires once. Returns the recovered
    /// recordings.
    @discardableResult
    public func recoverInterruptedSessions() async -> [URL] {
        let found = RecoveryScan.interruptedRecordings(in: archive.root)
        var recovered: [URL] = []
        for item in found {
            if let captureURL = item.captureURL {
                do {
                    try await RecordingFinalizer.finalize(
                        captureURL: captureURL,
                        to: item.audioURL
                    )
                    recovered.append(item.audioURL)
                } catch {
                    continue // leaves the `.caf` — retried next launch
                }
            }
            RecoveryScan.clearMarker(of: item)
        }
        if !recovered.isEmpty {
            notifier.post(
                title: recovered.count == 1
                    ? "Recovered a recording"
                    : "Recovered \(recovered.count) recordings",
                body: recovered.map(\.lastPathComponent).joined(separator: ", ")
            )
        }
        return recovered
    }

    /// The engine ended capture itself (input device lost mid-recording).
    /// Same finalize bookkeeping as `stopSession`, plus a hand-off to
    /// `AppState` so the menu returns to idle.
    private func captureStoppedByEngine() {
        guard let session = activeSession else { return }
        activeSession = nil
        Task { [weak self] in
            guard let self else { return }
            let finalized = await self.finalize(session)
            // "CHEM 101 — file.m4a"; Quick Record stays filename-only.
            let detail = [session.courseName, session.fileURL.lastPathComponent]
                .compactMap { $0 }
                .joined(separator: " — ")
            self.notifier.post(
                title: "Recording stopped — input device changed",
                body: finalized
                    ? detail
                    : "\(detail) — will recover on next launch"
            )
            self.onSessionInterrupted?(session)
        }
    }

    /// Transcodes the Session's `.caf` into its `.m4a` and clears the marker.
    /// On failure the marker stays, so the next launch's recovery pass
    /// retries — the `.caf` is still the source of truth.
    private func finalize(_ session: Session) async -> Bool {
        do {
            try await RecordingFinalizer.finalize(
                captureURL: CaptureFile.url(for: session.fileURL),
                to: session.fileURL
            )
            RecordingMarker.remove(for: session.fileURL)
            return true
        } catch {
            return false
        }
    }
}
