import AppKit
import Foundation

/// `ModelDownloadConsent` implemented as a modal `NSAlert` — the menu item
/// that triggered transcription has already dismissed the menu, so the prompt
/// arrives as its own window. The app is activated first because Mikey is a
/// menu-bar agent (`LSUIElement`) and the alert would otherwise open behind
/// whatever app is frontmost.
public struct AlertModelDownloadConsent: ModelDownloadConsent {
    public init() {}

    @MainActor
    public func requestConsent(model: String, approximateGB: Double) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download the Whisper model?"
        let size = String(format: "%.1f", approximateGB)
        alert.informativeText = """
            Transcription runs on-device with Whisper. The “\(model)” model \
            needs a one-time download of about \(size) GB; \
            after that every transcript works fully offline.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
