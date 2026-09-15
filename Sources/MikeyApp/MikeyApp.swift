import Mikey
import SwiftUI

/// Mikey — a menu-bar agent (LSUIElement: no Dock icon, not in Cmd-Tab).
/// The MenuBarExtra is the entire UI.
@main
struct MikeyApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(appState: appState)
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.menu)
    }
}
