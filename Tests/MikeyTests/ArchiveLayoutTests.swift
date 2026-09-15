import Foundation
import Testing
@testable import Mikey

/// Coverage for the Course→folder mapping and first-launch layout (SPEC §4):
/// slugification, deterministic `-2` on slug collisions, and the guarantee
/// that reconfiguring Courses never deletes or renames existing folders.
struct ArchiveLayoutTests {
    private let tempDir: URL
    private let archive: Archive

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        archive = Archive(root: tempDir)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func slugifyJoinsWordsWithDashes() {
        #expect(Archive.slugify("CHEM 101") == "CHEM-101")
        #expect(Archive.slugify("MATH 240") == "MATH-240")
        #expect(Archive.slugify("Organic Chem II") == "ORGANIC-CHEM-II")
        #expect(Archive.slugify("  chem   101  ") == "CHEM-101")
        #expect(Archive.slugify("Econ 305: Micro") == "ECON-305-MICRO")
        #expect(Archive.slugify("HIST-210") == "HIST-210")
    }

    @Test func slugifyFallbackForUnusableNames() {
        #expect(Archive.slugify("") == "COURSE")
        #expect(Archive.slugify("   ") == "COURSE")
        #expect(Archive.slugify("—") == "COURSE")
    }

    @Test func courseFoldersResolveInConfigOrder() {
        let folders = archive.courseFolders(for: ["CHEM 101", "MATH 240", "PHYS 150"])
        #expect(folders.map(\.name) == ["CHEM 101", "MATH 240", "PHYS 150"])
        #expect(
            folders.map(\.folder.lastPathComponent)
                == ["CHEM-101", "MATH-240", "PHYS-150"]
        )
    }

    @Test func slugCollisionGetsDeterministicSuffix() {
        // Two different Course names that slugify identically.
        let folders = archive.courseFolders(for: ["CHEM 101", "chem-101", "CHEM  101"])
        #expect(
            folders.map(\.folder.lastPathComponent)
                == ["CHEM-101", "CHEM-101-2", "CHEM-101-3"]
        )
        // Deterministic: same input, same output.
        #expect(
            archive.courseFolders(for: ["CHEM 101", "chem-101", "CHEM  101"])
                .map(\.folder.lastPathComponent)
                == ["CHEM-101", "CHEM-101-2", "CHEM-101-3"]
        )
    }

    @Test func courseNamedUnsortedCannotShadowQuickRecordFolder() {
        // APFS is case-insensitive by default, so "UNSORTED" would file into
        // `Unsorted/` — the resolver must bump it instead.
        let folders = archive.courseFolders(for: ["Unsorted"])
        #expect(folders.first?.folder.lastPathComponent == "UNSORTED-2")
    }

    @Test func ensureLayoutCreatesCourseFoldersAndUnsorted() throws {
        defer { cleanup() }
        try archive.ensureLayout(courses: ["CHEM 101", "MATH 240", "PHYS 150"])

        for slug in ["CHEM-101", "MATH-240", "PHYS-150", "Unsorted"] {
            #expect(exists(tempDir.appending(path: slug)))
        }
    }

    @Test func ensureLayoutNeverDeletesOrRenames() throws {
        defer { cleanup() }
        try archive.ensureLayout(courses: ["CHEM 101"])
        // A Recording exists under the old Course's folder.
        let recording = tempDir.appending(path: "CHEM-101/2026-09-15_10-30.m4a")
        try Data([0x00]).write(to: recording)

        // Semester change: the Course list is replaced entirely.
        try archive.ensureLayout(courses: ["BIO 110"])

        #expect(exists(tempDir.appending(path: "CHEM-101"))) // still there
        #expect(exists(recording))                            // untouched
        #expect(exists(tempDir.appending(path: "BIO-110")))   // new folder added
    }

    @Test func sessionURLInsideCourseFolder() throws {
        defer { cleanup() }
        let course = archive.courseFolders(for: ["CHEM 101"]).first!

        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 15
        components.hour = 10; components.minute = 30
        let date = Calendar.current.date(from: components)!

        let url = try archive.newSessionURL(at: date, in: course.folder)
        #expect(
            url.path(percentEncoded: false)
                == tempDir.appending(path: "CHEM-101/2026-09-15_10-30.m4a")
                    .path(percentEncoded: false)
        )

        // Same course, same minute → `-2`; a Quick Record at the same minute
        // lives in Unsorted/ and does not collide.
        FileManager.default.createFile(
            atPath: url.path(percentEncoded: false), contents: Data()
        )
        let second = try archive.newSessionURL(at: date, in: course.folder)
        #expect(second.lastPathComponent == "2026-09-15_10-30-2.m4a")

        let quick = try archive.newSessionURL(at: date)
        #expect(quick.lastPathComponent == "2026-09-15_10-30.m4a")
        #expect(quick.deletingLastPathComponent().lastPathComponent == "Unsorted")
    }
}
