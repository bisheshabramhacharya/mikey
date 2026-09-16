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
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Button("Stop Recording — \(session.courseName ?? "Quick Record") · \(elapsedString(appState.elapsedTime))") {
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

        // Pending Sessions — Recordings without Transcripts (SPEC §2, §6).
        // One Transcribe action each; "Transcribe All" is a later ticket.
        if !appState.pendingSessions.isEmpty {
            Divider()
            Text("Pending")
            ForEach(appState.pendingSessions) { session in
                Button("Transcribe — \(session.menuLabel)") {
                    Task { await appState.transcribe(session) }
                }
                .disabled(appState.transcriptionState != .idle)
            }
        }

        switch appState.transcriptionState {
        case .idle:
            EmptyView()
        case .downloadingModel(let progress):
            Text("Downloading Whisper model… \(Int(progress * 100))%")
        case .loadingModel:
            Text("Loading Whisper model…")
        case .transcribing(let session, let progress):
            Text("\(session.menuLabel) — transcribing… \(Int(progress * 100))%")
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
