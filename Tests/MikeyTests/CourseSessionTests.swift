import Foundation
import Testing
@testable import Mikey

/// End-to-end coverage of issue #3's menu flow: config load → Course list →
/// record into the Course's folder, and the corrupt-config degradation where
/// Quick Record keeps working (SPEC §5, §7).
@MainActor
struct CourseSessionTests {
    private let tempDir: URL
    private let engine: FakeRecordingEngine
    private let notifier: FakeNotifier
    private let appState: AppState
    private let configURL: URL

    private static var sessionStart: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 15
        components.hour = 10; components.minute = 30
        return Calendar.current.date(from: components)!
    }

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        configURL = tempDir.appending(path: "config.json")
        engine = FakeRecordingEngine()
        notifier = FakeNotifier()
        appState = AppState(
            sessions: SessionController(
                engine: engine,
                archive: Archive(root: tempDir),
                clock: FixedClock(now: Self.sessionStart),
                notifier: notifier
            )
        )
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeConfig(_ contents: String) throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: configURL)
    }

    @Test func firstLoadCreatesArchiveWithDefaults() throws {
        defer { cleanup() }
        appState.reloadConfig()

        #expect(FileManager.default.fileExists(atPath: configURL.path))
        #expect(appState.courseFolders.map(\.name) == ["CHEM 101", "MATH 240", "PHYS 150"])

        // First-launch layout: one folder per Course + Unsorted/.
        for slug in ["CHEM-101", "MATH-240", "PHYS-150", "Unsorted"] {
            #expect(
                FileManager.default.fileExists(
                    atPath: tempDir.appending(path: slug).path
                )
            )
        }
    }

    @Test func recordCourseFilesSessionUnderCourseFolder() async throws {
        defer { cleanup() }
        appState.reloadConfig()
        let chem = try #require(appState.courseFolders.first)

        await appState.recordCourse(chem)

        guard case .recording(let session) = appState.recordingState else {
            Issue.record("expected .recording")
            return
        }
        #expect(session.courseName == "CHEM 101")
        #expect(
            session.fileURL.path(percentEncoded: false)
                == tempDir.appending(path: "CHEM-101/2026-09-15_10-30.m4a")
                    .path(percentEncoded: false)
        )
        // Live capture goes to the crash-safe `.caf` sibling; `fileURL` is
        // the `.m4a` produced on finalize (#5).
        #expect(engine.startedURL == CaptureFile.url(for: session.fileURL))
    }

    @Test func quickRecordStillFilesToUnsorted() async throws {
        defer { cleanup() }
        appState.reloadConfig()

        await appState.quickRecord()

        guard case .recording(let session) = appState.recordingState else {
            Issue.record("expected .recording")
            return
        }
        #expect(session.courseName == nil)
        #expect(session.fileURL.deletingLastPathComponent().lastPathComponent == "Unsorted")
    }

    @Test func editingConfigChangesCoursesOnReload() throws {
        defer { cleanup() }
        appState.reloadConfig()

        try writeConfig("""
        {
          "courses": ["BIO 110", "HIST 210"],
          "autoStopMinutes": 75,
          "gainDB": 12,
          "whisperModel": "large-v3-turbo",
          "archivePath": "~/Documents/Mikey"
        }
        """)
        appState.reloadConfig()

        #expect(appState.courseFolders.map(\.name) == ["BIO 110", "HIST 210"])
        #expect(
            appState.courseFolders.map(\.folder.lastPathComponent)
                == ["BIO-110", "HIST-210"]
        )
        // The old course folders were left alone.
        #expect(
            FileManager.default.fileExists(
                atPath: tempDir.appending(path: "CHEM-101").path
            )
        )
    }

    @Test func corruptConfigWarnsAndQuickRecordStillWorks() async throws {
        defer { cleanup() }
        try writeConfig("not json at all {{{")
        appState.reloadConfig()

        guard case .corrupt = appState.configState else {
            Issue.record("expected .corrupt configState")
            return
        }
        #expect(appState.courseFolders.isEmpty)

        // Quick Record remains available while the config is broken.
        await appState.quickRecord()
        guard case .recording(let session) = appState.recordingState else {
            Issue.record("expected Quick Record to work despite corrupt config")
            return
        }
        #expect(session.fileURL.deletingLastPathComponent().lastPathComponent == "Unsorted")
    }

    @Test func fixingCorruptConfigRestoresCourses() throws {
        defer { cleanup() }
        try writeConfig("{{{")
        appState.reloadConfig()
        #expect(appState.courseFolders.isEmpty)

        try writeConfig("""
        {
          "courses": ["CHEM 101", "MATH 240", "PHYS 150"],
          "autoStopMinutes": 75,
          "gainDB": 12,
          "whisperModel": "large-v3-turbo",
          "archivePath": "~/Documents/Mikey"
        }
        """)
        appState.reloadConfig()

        #expect(appState.courseFolders.map(\.name) == ["CHEM 101", "MATH 240", "PHYS 150"])
    }
}
