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

    private let sessions: SessionController

    public init(sessions: SessionController = SessionController()) {
        self.sessions = sessions
    }

    public var archiveURL: URL { sessions.archiveURL }
    public var elapsedTime: TimeInterval { sessions.elapsedTime }
    public var inputLevel: Float { sessions.inputLevel }

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
