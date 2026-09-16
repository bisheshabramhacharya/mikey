import Foundation
import Testing
@testable import Mikey

/// The config's recording knobs (`gainDB`, `autoStopMinutes`) are baked into
/// the engine/controller when `AppState` builds its own — this proves the
/// file reaches capture instead of sitting as dead keys (SPEC §5).
@MainActor
struct ConfigKnobsTests {
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeConfig(_ contents: String) throws {
        try Data(contents.utf8).write(
            to: Archive(root: tempDir).configFileURL
        )
    }

    @Test func configKnobsReachTheController() throws {
        defer { cleanup() }
        try writeConfig("""
        {
          "courses": ["CHEM 101"],
          "autoStopMinutes": 60,
          "gainDB": 6.5,
          "whisperModel": "large-v3-turbo",
          "archivePath": "~/Documents/Mikey"
        }
        """)

        // No `sessions:` — the path MikeyApp takes.
        let appState = AppState(configStore: ConfigStore(archive: Archive(root: tempDir)))

        #expect(appState.sessions.autoStopLimit == 3600)
        #expect((appState.sessions.engine as? MicRecordingEngine)?.gainDB == 6.5)
    }

    @Test func missingConfigBuildsWithSpecDefaults() {
        defer { cleanup() }
        let appState = AppState(configStore: ConfigStore(archive: Archive(root: tempDir)))

        #expect(appState.sessions.autoStopLimit == SessionController.defaultAutoStopLimit)
        #expect(
            (appState.sessions.engine as? MicRecordingEngine)?.gainDB
                == GainStage.defaultGainDB
        )
    }

    @Test func corruptConfigBuildsWithSpecDefaults() throws {
        defer { cleanup() }
        try writeConfig("{ not json")

        let appState = AppState(configStore: ConfigStore(archive: Archive(root: tempDir)))

        #expect(appState.sessions.autoStopLimit == SessionController.defaultAutoStopLimit)
        #expect(
            (appState.sessions.engine as? MicRecordingEngine)?.gainDB
                == GainStage.defaultGainDB
        )
        guard case .corrupt = appState.configState else {
            Issue.record("expected .corrupt config state")
            return
        }
    }
}
