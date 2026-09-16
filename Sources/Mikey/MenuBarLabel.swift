import SwiftUI

/// Formats elapsed capture time as `mm:ss` for the menu bar and Stop item.
public func elapsedString(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d", total / 60, total % 60)
}

/// The menu-bar icon. Idle: static mic glyph. Recording: a pulsing red dot +
/// elapsed `mm:ss`. Transcribing with no Session running: a waveform cycling
/// its variable-color layers — background work a glance can tell apart from
/// the recording pulse (SPEC §2). All live data comes from the single ticker
/// publishing into `AppState` — the view holds no timer of its own: the dot's
/// opacity follows `recordingPulse`, which the ticker flips each beat, and
/// both symbol effects repeat on their own.
public struct MenuBarLabel: View {
    let appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        switch appState.recordingState {
        case .idle:
            if appState.isTranscribing {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
            } else {
                Image(systemName: "mic")
            }
        case .recording:
            HStack(spacing: 3) {
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
                    .opacity(appState.recordingPulse ? 1 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.3),
                        value: appState.recordingPulse
                    )
                Text(elapsedString(appState.elapsedTime))
                    .monospacedDigit()
            }
        }
    }
}
