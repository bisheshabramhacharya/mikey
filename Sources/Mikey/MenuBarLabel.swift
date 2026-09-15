import SwiftUI

/// Formats elapsed capture time as `mm:ss` for the menu bar and Stop item.
public func elapsedString(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d", total / 60, total % 60)
}

/// The menu-bar icon. Idle: static mic glyph. Recording: filled dot + elapsed
/// `mm:ss`, refreshed on a timeline. (The pulsing animation arrives with the
/// trust-polish ticket.)
public struct MenuBarLabel: View {
    let appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        switch appState.recordingState {
        case .idle:
            Image(systemName: "mic")
        case .recording:
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                HStack(spacing: 3) {
                    Image(systemName: "record.circle.fill")
                    Text(elapsedString(appState.elapsedTime))
                        .monospacedDigit()
                }
            }
        }
    }
}
