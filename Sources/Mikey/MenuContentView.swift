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
            ForEach(appState.courseFolders) { course in
                Button("▶ \(course.name)") {
                    Task { await appState.recordCourse(course) }
                }
            }
            Button("▶ Quick Record") {
                Task { await appState.quickRecord() }
            }
        case .recording(let session):
            // Elapsed + meter both read the ticker's published snapshot —
            // no per-view timers (SPEC §2).
            Button("■ Stop Recording — \(session.courseName ?? "Quick Record") · \(elapsedString(appState.elapsedTime))") {
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

        // Corrupt config → warning + fix affordance; the Course list is
        // already empty and Quick Record above keeps working (SPEC §5, §7).
        if case .corrupt(let detail) = appState.configState {
            Button("⚠ Config error — click to fix") {
                appState.editConfig()
            }
            Text(detail)
        }

        Divider()

        Button("Open Archive Folder") {
            appState.openArchiveFolder()
        }
        Button("Edit Courses (config.json)") {
            appState.editConfig()
        }

        Divider()

        Button("Quit Mikey") {
            appState.quit()
        }
        .keyboardShortcut("q")
        // `.menu`-style MenuBarExtra re-renders its content on every open, so
        // this is the "reload config when the menu opens" hook — no watcher.
        .onAppear { appState.reloadConfig() }
    }
}
