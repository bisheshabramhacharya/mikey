import SwiftUI

/// The whole menu. Idle shows the record action; recording swaps to the Stop
/// view — starting a second Session while one runs is impossible by
/// construction (SPEC §7).
public struct MenuContentView: View {
    let appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        switch appState.recordingState {
        case .idle:
            Button("Quick Record") {
                Task { await appState.quickRecord() }
            }
        case .recording:
            // Elapsed + meter both read the ticker's published snapshot —
            // no per-view timers (SPEC §2).
            Button("■ Stop Recording — \(elapsedString(appState.elapsedTime))") {
                appState.stopRecording()
            }
            // Live proof the mic hears the room. Room-tone speech is RMS ≪ 1,
            // so the bar is scaled to a quarter full-scale.
            LabeledContent("Input level") {
                ProgressView(
                    value: Double(min(appState.inputLevel, 0.25) / 0.25)
                )
                .frame(width: 80)
            }
        }

        if let error = appState.lastError {
            Text(error)
        }

        Divider()

        Button("Open Archive Folder") {
            appState.openArchiveFolder()
        }

        Divider()

        Button("Quit Mikey") {
            appState.quit()
        }
        .keyboardShortcut("q")
    }
}
