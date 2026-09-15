import AppKit

/// The confirm-and-terminate flow behind `Quit Mikey` while a Session is
/// running (SPEC §7). Behind a protocol so tests can fake the answer — a real
/// `terminate` would kill the test runner mid-suite.
@MainActor
public protocol QuitFlow {
    /// Warns the user that a Session is still recording.
    /// Returns `true` to finalize the file and quit, `false` to keep recording.
    func confirmQuitWhileRecording() -> Bool
    /// Ends the app (`NSApplication.terminate`).
    func terminateNow()
}

/// `QuitFlow` backed by a warning `NSAlert`. The app is a menu-bar agent with
/// no key window, so it activates itself first — otherwise the alert can open
/// behind other apps' windows while the menu stays up.
public final class AppQuitFlow: QuitFlow {
    public init() {}

    public func confirmQuitWhileRecording() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stop recording and quit Mikey?"
        alert.informativeText =
            "A Session is still recording. Quitting stops it cleanly — " +
            "the .m4a stays in the Archive."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop Recording & Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func terminateNow() {
        NSApplication.shared.terminate(nil)
    }
}
