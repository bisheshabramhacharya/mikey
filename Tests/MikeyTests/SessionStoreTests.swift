import Foundation
import Testing
@testable import Mikey

/// Pending detection: an `.m4a` with no sibling `.md` is pending (SPEC §4/§6).
/// The scan is filesystem-derived — course folders and `Unsorted/` one level
/// below the root, labels resolved through the config's Course list.
struct SessionStoreTests {
    private let tempDir: URL
    private let archive: Archive
    private let store: SessionStore

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        archive = Archive(root: tempDir)
        store = SessionStore(archive: archive)
        try archive.ensureLayout(courses: ["CHEM 101", "MATH 240"])
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var courses: [CourseFolder] {
        archive.courseFolders(for: ["CHEM 101", "MATH 240"])
    }

    @discardableResult
    private func touch(_ relative: String) throws -> URL {
        let url = tempDir.appending(path: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x00]).write(to: url)
        return url
    }

    @Test func m4aWithoutSiblingMarkdownIsPending() throws {
        defer { cleanup() }
        try touch("CHEM-101/2026-09-15_10-30.m4a")
        try touch("CHEM-101/2026-09-17_10-30.m4a")
        try touch("CHEM-101/2026-09-17_10-30.md") // transcribed → not pending

        let pending = store.pendingSessions(courseFolders: courses)

        #expect(pending.map(\.audioURL.lastPathComponent) == ["2026-09-15_10-30.m4a"])
        #expect(pending.first?.courseLabel == "CHEM 101")
    }

    @Test func pendingSortsNewestFirst() throws {
        defer { cleanup() }
        try touch("CHEM-101/2026-09-15_10-30.m4a")
        try touch("Unsorted/2026-09-18_18-02.m4a")
        try touch("MATH-240/2026-09-16_09-00.m4a")

        let pending = store.pendingSessions(courseFolders: courses)

        #expect(
            pending.map(\.audioURL.lastPathComponent) == [
                "2026-09-18_18-02.m4a",
                "2026-09-16_09-00.m4a",
                "2026-09-15_10-30.m4a",
            ]
        )
    }

    @Test func leftoverTmpDoesNotMarkSessionTranscribed() throws {
        defer { cleanup() }
        try touch("CHEM-101/2026-09-15_10-30.m4a")
        // An interrupted job's orphan — only a real `.md` counts.
        try touch("CHEM-101/2026-09-15_10-30.md.tmp")

        #expect(store.pendingSessions(courseFolders: courses).count == 1)
    }

    @Test func quickRecordSessionsLabelUnsorted() throws {
        defer { cleanup() }
        try touch("Unsorted/2026-09-16_18-02.m4a")

        let pending = store.pendingSessions(courseFolders: courses)

        #expect(pending.first?.courseLabel == "Unsorted")
        #expect(pending.first?.menuLabel == "Unsorted · 2026-09-16 18:02")
    }

    @Test func removedCourseFolderStillScannedUnderItsOwnName() throws {
        defer { cleanup() }
        // A folder left over from a Course no longer in the config (§7).
        try touch("HIST-210/2026-03-01_14-00.m4a")

        let pending = store.pendingSessions(courseFolders: courses)

        #expect(pending.first?.courseLabel == "HIST-210")
    }

    @Test func collisionSuffixParsesToSameSessionStart() throws {
        defer { cleanup() }
        try touch("CHEM-101/2026-09-15_10-30-2.m4a")

        let pending = store.pendingSessions(courseFolders: courses)

        #expect(pending.first?.menuLabel == "CHEM 101 · 2026-09-15 10:30")
    }

    @Test func nonRecordingsAndDeepFilesAreIgnored() throws {
        defer { cleanup() }
        try touch("CHEM-101/notes.txt")
        try touch("CHEM-101/nested/2026-09-15_10-30.m4a") // Sessions sit one level down
        try touch("2026-09-15_10-30.m4a")                // stray file at the root
        try touch("config.json")

        #expect(store.pendingSessions(courseFolders: courses).isEmpty)
    }

    @Test func unparseableNameFallsBackToFileDate() throws {
        defer { cleanup() }
        let file = try touch("CHEM-101/voice-memo.m4a")

        let pending = store.pendingSessions(courseFolders: courses)

        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        #expect(pending.first?.startedAt == modified)
        #expect(pending.first?.courseLabel == "CHEM 101")
    }

    @Test func emptyArchiveScansEmpty() throws {
        defer { cleanup() }
        #expect(store.pendingSessions(courseFolders: courses).isEmpty)
    }
}
