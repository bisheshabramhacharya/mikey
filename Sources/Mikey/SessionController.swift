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

    private let engine: any RecordingEngine
    private let archive: Archive
    private let clock: any Clock
    private let notifier: any NotificationPosting

    public init(
        engine: any RecordingEngine = MicRecordingEngine(),
        archive: Archive = Archive(),
        clock: any Clock = SystemClock(),
        notifier: any NotificationPosting = UserNotificationPoster()
    ) {
        self.engine = engine
        self.archive = archive
        self.clock = clock
        self.notifier = notifier
    }

    public var archiveURL: URL { archive.root }
    public var elapsedTime: TimeInterval { engine.elapsedTime }
    public var inputLevel: Float { engine.inputLevel }

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
        return Session(fileURL: url, startedAt: startedAt)
    }

    /// Ends the Session: capture stops, the `.m4a` is finalized, and a
    /// notification confirms the stop (SPEC §1).
    public func stopSession(_ session: Session) {
        engine.stop()
        notifier.post(
            title: "Recording stopped",
            body: session.fileURL.lastPathComponent
        )
    }
}
