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
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Button("Stop Recording — \(elapsedString(appState.elapsedTime))") {
                    appState.stopRecording()
                }
            }
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                // Room-tone speech is RMS ≪ 1, so the bar is scaled to a
                // quarter full-scale. The real meter UI is a later ticket.
                LabeledContent("Input level") {
                    ProgressView(value: Double(min(appState.inputLevel, 0.25) / 0.25))
                        .frame(width: 80)
                }
            }
        }

        if !appState.recoveredFiles.isEmpty {
            Text("Recovered after an unexpected quit: \(appState.recoveredFiles.map(\.lastPathComponent).joined(separator: ", "))")
        }

        if let error = appState.lastError {
            Text(error)
            if let fix = appState.errorFix {
                switch fix {
                case .openMicrophoneSettings:
                    Button("Open Microphone Settings…") {
                        appState.openMicrophoneSettings()
                    }
                }
            }
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
