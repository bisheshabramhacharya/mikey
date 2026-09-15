import Foundation

/// A single recorded class meeting — here always a Quick Record (courseless).
/// Its Recording is one `.m4a` written to `fileURL`.
public struct Session: Equatable, Sendable {
    /// Where this Session's Recording lands in the Archive.
    public let fileURL: URL
    public let startedAt: Date

    public init(fileURL: URL, startedAt: Date) {
        self.fileURL = fileURL
        self.startedAt = startedAt
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

        public var errorDescription: String? {
            switch self {
            case .microphoneAccessDenied:
                "Microphone access is denied — allow Mikey under System Settings → Privacy → Microphone."
            case .archiveUnavailable(let detail):
                "Couldn't prepare the Archive: \(detail)"
            case .captureFailed(let detail):
                "Couldn't start recording: \(detail)"
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

    private let engine: any RecordingEngine
    private let archive: Archive
    private let clock: any Clock
    private let notifier: any NotificationPosting
    private let sleepAssertion: any SleepAssertion

    public init(
        engine: any RecordingEngine = MicRecordingEngine(),
        archive: Archive = Archive(),
        clock: any Clock = SystemClock(),
        notifier: any NotificationPosting = UserNotificationPoster(),
        sleepAssertion: any SleepAssertion = ProcessInfoSleepAssertion(),
        autoStopLimit: TimeInterval = SessionController.defaultAutoStopLimit
    ) {
        self.engine = engine
        self.archive = archive
        self.clock = clock
        self.notifier = notifier
        self.sleepAssertion = sleepAssertion
        self.autoStopLimit = autoStopLimit
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

    /// Starts a Quick Record Session filed under `Archive/Unsorted/`.
    public func startSession() async throws -> Session {
        guard await engine.requestAccess() else {
            throw Failure.microphoneAccessDenied
        }
        let startedAt = clock.now
        let url: URL
        do {
            url = try archive.newSessionURL(at: startedAt)
        } catch {
            throw Failure.archiveUnavailable(error.localizedDescription)
        }
        do {
            try engine.start(to: url)
        } catch {
            throw Failure.captureFailed(error.localizedDescription)
        }
        // Only after capture is actually running: the Mac may not idle-sleep
        // for the whole Session. Held until `stopSession` — every exit path
        // (manual, auto-stop, quit-confirm) funnels through there.
        sleepAssertion.begin()
        return Session(fileURL: url, startedAt: startedAt)
    }

    /// Ends the Session: capture stops, the sleep assertion is released, the
    /// `.m4a` is finalized, and a notification confirms the stop (SPEC §1/§3).
    public func stopSession(
        _ session: Session,
        reason: StopReason = .manual
    ) {
        engine.stop()
        sleepAssertion.end()
        switch reason {
        case .manual:
            notifier.post(
                title: "Recording stopped",
                body: session.fileURL.lastPathComponent
            )
        case .autoStop:
            notifier.post(
                title: "Recording auto-stopped (\(elapsedString(autoStopLimit)))",
                body: session.fileURL.lastPathComponent
            )
        }
    }
}
