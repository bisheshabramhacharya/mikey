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

    private let sessions: SessionController

    public init(sessions: SessionController = SessionController()) {
        self.sessions = sessions
        sessions.onSessionInterrupted = { [weak self] session in
            guard let self,
                  case .recording(let current) = self.recordingState,
                  current == session else { return }
            self.recordingState = .idle
        }
        // Recovery transcodes leftover `.caf` captures — real work, so it
        // runs off the init path and lands here when done.
        Task { [weak self] in
            let recovered = await sessions.recoverInterruptedSessions()
            self?.recoveredFiles = recovered
        }
    }

    public var archiveURL: URL { sessions.archiveURL }
    public var elapsedTime: TimeInterval { sessions.elapsedTime }
    public var inputLevel: Float { sessions.inputLevel }

    /// Menu action: `▶ Quick Record`. Starts a courseless Session filed under
    /// `Archive/Unsorted/`. Mic permission is requested on first use.
    public func quickRecord() async {
        guard recordingState == .idle else { return }
        lastError = nil
        errorFix = nil
        recoveredFiles = []
        do {
            let session = try await sessions.startSession()
            recordingState = .recording(session)
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
        recordingState = .idle
        Task { await sessions.stopSession(session) }
    }

    /// Menu action: `Open Archive Folder` — reveals the Archive in Finder.
    public func openArchiveFolder() {
        try? sessions.archiveURL.createDirectoryWithIntermediates()
        NSWorkspace.shared.open(sessions.archiveURL)
    }

    /// Menu action shown when mic permission is denied — deep-links to
    /// System Settings → Privacy → Microphone (SPEC §7).
    public func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Menu action: `Quit Mikey`. Waits for a running Session to finish
    /// finalizing first so the `.m4a` lands cleanly. (A confirm-before-quit
    /// prompt lands with the trust-polish ticket.)
    public func quit() {
        guard case .recording(let session) = recordingState else {
            NSApplication.shared.terminate(nil)
            return
        }
        recordingState = .idle
        Task {
            await sessions.stopSession(session)
            NSApplication.shared.terminate(nil)
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
