import Foundation
import Testing
@testable import Mikey

/// `config.json` lifecycle coverage: first-launch defaults, reload on menu
/// open, and the corrupt-file path the menu warns about (SPEC §5, §7).
struct ConfigStoreTests {
    private let tempDir: URL
    private let archive: Archive
    private let store: ConfigStore

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        archive = Archive(root: tempDir)
        store = ConfigStore(archive: archive)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ contents: String) throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: store.fileURL)
    }

    @Test func missingFileWritesDefaultsAndReturnsThem() throws {
        defer { cleanup() }
        // The Archive root itself doesn't exist yet — first launch.
        #expect(!FileManager.default.fileExists(atPath: tempDir.path))

        guard case .ok(let config) = store.load() else {
            Issue.record("expected .ok, got \(store.load())")
            return
        }

        #expect(config == .standard)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

        // The written file decodes back to the same defaults.
        let data = try Data(contentsOf: store.fileURL)
        #expect(try JSONDecoder().decode(Config.self, from: data) == .standard)
    }

    @Test func defaultsMatchSpecShape() throws {
        defer { cleanup() }
        _ = store.load()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL))
        guard let dict = object as? [String: Any] else {
            Issue.record("config.json is not a JSON object")
            return
        }
        #expect(dict["courses"] as? [String] == ["CHEM 101", "MATH 240", "PHYS 150"])
        #expect(dict["autoStopMinutes"] as? Int == 75)
        #expect(dict["gainDB"] as? Double == 12)
        #expect(dict["whisperModel"] as? String == "large-v3-turbo")
        #expect(dict["archivePath"] as? String == "~/Documents/Mikey")
    }

    @Test func validFileLoadsUserValues() throws {
        defer { cleanup() }
        try write("""
        {
          "courses": ["BIO 110", "HIST 210"],
          "autoStopMinutes": 60,
          "gainDB": 6.5,
          "whisperModel": "small",
          "archivePath": "~/Documents/Mikey"
        }
        """)

        guard case .ok(let config) = store.load() else {
            Issue.record("expected .ok, got \(store.load())")
            return
        }
        #expect(config.courses == ["BIO 110", "HIST 210"])
        #expect(config.autoStopMinutes == 60)
        #expect(config.gainDB == 6.5)
        #expect(config.whisperModel == "small")
    }

    @Test func editsAreSeenOnNextLoad() throws {
        defer { cleanup() }
        _ = store.load()

        try write("""
        {
          "courses": ["ECON 305"],
          "autoStopMinutes": 75,
          "gainDB": 12,
          "whisperModel": "large-v3-turbo",
          "archivePath": "~/Documents/Mikey"
        }
        """)

        guard case .ok(let config) = store.load() else {
            Issue.record("expected .ok after edit")
            return
        }
        #expect(config.courses == ["ECON 305"])
    }

    @Test func corruptFileReportsErrorAndIsNotOverwritten() throws {
        defer { cleanup() }
        let garbage = "{ this is not json"
        try write(garbage)

        guard case .corrupt(let message) = store.load() else {
            Issue.record("expected .corrupt, got \(store.load())")
            return
        }
        #expect(!message.isEmpty)

        // Left untouched so the user (or "click to fix") can repair it.
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == garbage)
    }

    @Test func wrongShapeReportsCorrupt() throws {
        defer { cleanup() }
        try write(#"{"courses": "CHEM 101"}"#)

        guard case .corrupt = store.load() else {
            Issue.record("expected .corrupt for wrong-typed courses")
            return
        }
    }

    @Test func missingKeyReportsCorrupt() throws {
        defer { cleanup() }
        try write("""
        {
          "courses": ["CHEM 101"],
          "autoStopMinutes": 75
        }
        """)

        guard case .corrupt = store.load() else {
            Issue.record("expected .corrupt for incomplete config")
            return
        }
    }

    @Test func emptyFileReportsCorrupt() throws {
        defer { cleanup() }
        try write("")

        guard case .corrupt = store.load() else {
            Issue.record("expected .corrupt for empty file")
            return
        }
    }
}
