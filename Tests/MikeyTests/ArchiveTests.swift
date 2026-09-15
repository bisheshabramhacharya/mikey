import Foundation
import Testing
@testable import Mikey

struct ArchiveTests {
    private let tempDir: URL
    private let archive: Archive

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        archive = Archive(root: tempDir)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Parses "2026-09-15 10:30" in the local time zone — the same convention
    /// the filename uses, so the assertion holds on any test machine.
    private func sessionStart() -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter.date(from: "2026-09-15 10-30")!
    }

    @Test func defaultRootIsDocumentsMikey() {
        #expect(
            Archive.defaultRoot().path(percentEncoded: false)
                == FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Documents/Mikey").path(percentEncoded: false)
        )
    }

    @Test func sessionURLNamesFileByStartTime() throws {
        defer { cleanup() }
        let url = try archive.newSessionURL(at: sessionStart())
        #expect(
            url.path(percentEncoded: false)
                == tempDir.appending(path: "Unsorted/2026-09-15_10-30.m4a")
                    .path(percentEncoded: false)
        )
    }

    @Test func sessionURLCreatesUnsortedFolder() throws {
        defer { cleanup() }
        #expect(
            !FileManager.default.fileExists(atPath: archive.unsortedFolder.path)
        )
        _ = try archive.newSessionURL(at: sessionStart())
        #expect(
            FileManager.default.fileExists(atPath: archive.unsortedFolder.path)
        )
    }

    @Test func sameMinuteCollisionGetsNumericSuffix() throws {
        defer { cleanup() }
        let first = try archive.newSessionURL(at: sessionStart())
        FileManager.default.createFile(atPath: first.path, contents: Data())

        let second = try archive.newSessionURL(at: sessionStart())
        #expect(second.lastPathComponent == "2026-09-15_10-30-2.m4a")

        FileManager.default.createFile(atPath: second.path, contents: Data())
        let third = try archive.newSessionURL(at: sessionStart())
        #expect(third.lastPathComponent == "2026-09-15_10-30-3.m4a")
    }

    @Test func elapsedStringFormatsMMSS() {
        #expect(elapsedString(0) == "00:00")
        #expect(elapsedString(75) == "01:15")
        #expect(elapsedString(3_599) == "59:59")
        #expect(elapsedString(3_661) == "61:01")
        #expect(elapsedString(4_500.6) == "75:00")
    }
}
