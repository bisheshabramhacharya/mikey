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
    private let ticker: any Ticker
    private let quitFlow: any QuitFlow

    public init(
        sessions: SessionController = SessionController(),
        ticker: any Ticker = TimerTicker(),
        quitFlow: any QuitFlow = AppQuitFlow()
    ) {
        self.sessions = sessions
        self.ticker = ticker
        self.quitFlow = quitFlow
    }

    public var archiveURL: URL { sessions.archiveURL }

    /// Menu action: `▶ Quick Record`. Starts a courseless Session filed under
    /// `Archive/Unsorted/`. Mic permission is requested on first use.
    public func quickRecord() async {
        guard recordingState == .idle else { return }
        lastError = nil
        do {
            let session = try await sessions.startSession()
            elapsedTime = 0
            inputLevel = 0
            recordingPulse = false
            recordingState = .recording(session)
            ticker.start(every: Self.recordingTickInterval) { [weak self] in
                self?.handleTick()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Menu action: `■ Stop Recording`. Finalizes the `.m4a`.
    public func stopRecording() {
        guard case .recording(let session) = recordingState else { return }
        finishRecording(session, reason: .manual)
    }

    /// Menu action: `Open Archive Folder` — reveals the Archive in Finder.
    public func openArchiveFolder() {
        try? sessions.archiveURL.createDirectoryWithIntermediates()
        NSWorkspace.shared.open(sessions.archiveURL)
    }

    /// Menu action: `Quit Mikey`. Quitting mid-Session warns first (SPEC §7):
    /// confirm runs the normal finalize path, cancel keeps recording.
    public func quit() {
        if case .recording = recordingState {
            guard quitFlow.confirmQuitWhileRecording() else { return }
            stopRecording()
        }
        quitFlow.terminateNow()
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
    /// the cap, and quit-confirm: halt the ticker, stop + finalize + release
    /// the sleep assertion in `stopSession`, then reset the UI snapshot.
    private func finishRecording(
        _ session: Session,
        reason: SessionController.StopReason
    ) {
        ticker.stop()
        sessions.stopSession(session, reason: reason)
        recordingState = .idle
        elapsedTime = 0
        inputLevel = 0
        recordingPulse = false
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
