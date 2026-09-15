import Foundation

/// The app's persisted configuration — `<Archive>/config.json`, edited by hand
/// ("Edit Courses" opens it in the default editor). All keys are required; a
/// file missing any of them is treated as corrupt rather than silently
/// partially-defaulted (SPEC §5).
public struct Config: Codable, Equatable, Sendable {
    /// The Course names shown as record actions in the menu, in order.
    public var courses: [String]
    /// Hard cap on Session length — recording auto-stops here (75).
    public var autoStopMinutes: Int
    /// Mic boost applied in the capture pipeline, in dB (12).
    public var gainDB: Double
    /// WhisperKit model used for Transcripts ("large-v3-turbo").
    public var whisperModel: String
    /// Archive root as written in the file ("~/Documents/Mikey").
    public var archivePath: String

    public init(
        courses: [String],
        autoStopMinutes: Int,
        gainDB: Double,
        whisperModel: String,
        archivePath: String
    ) {
        self.courses = courses
        self.autoStopMinutes = autoStopMinutes
        self.gainDB = gainDB
        self.whisperModel = whisperModel
        self.archivePath = archivePath
    }

    /// Written on first launch — three placeholder Courses the user renames
    /// to their real classes (SPEC §5).
    public static let standard = Config(
        courses: ["CHEM 101", "MATH 240", "PHYS 150"],
        autoStopMinutes: 75,
        gainDB: 12,
        whisperModel: "large-v3-turbo",
        archivePath: "~/Documents/Mikey"
    )
}

/// Loads `<Archive>/config.json`. A missing file is created with
/// `Config.standard`; a corrupt one is reported, never overwritten — the user
/// repairs it by hand (SPEC §7). Cheap enough to call on every menu open,
/// which is how config edits apply without a file-watcher or restart.
public struct ConfigStore: Sendable {
    /// The outcome the menu renders: the Course list, or a warning + fix
    /// affordance when the file can't be parsed.
    public enum State: Equatable, Sendable {
        case ok(Config)
        /// `message` is a human-readable parse/read/write failure.
        case corrupt(String)
    }

    public let archive: Archive

    public init(archive: Archive = Archive()) {
        self.archive = archive
    }

    /// Where the config lives on disk (`<Archive>/config.json`).
    public var fileURL: URL { archive.configFileURL }

    /// Reads the config. Missing file → creates the Archive root and writes
    /// `Config.standard`, returning `.ok(.standard)`. Unreadable or
    /// undecodable file → `.corrupt` with the underlying error's description.
    public func load() -> State {
        guard FileManager.default.fileExists(
            atPath: fileURL.path(percentEncoded: false)
        ) else {
            return writeDefaults()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return .ok(try JSONDecoder().decode(Config.self, from: data))
        } catch {
            return .corrupt(error.localizedDescription)
        }
    }

    /// First-launch path: lay down the Archive root + a default config file.
    /// A write failure is reported as `.corrupt` — the Archive is effectively
    /// unusable and the menu should say so.
    private func writeDefaults() -> State {
        do {
            try archive.createIfNeeded()
            // Sorted keys keep the generated file deterministic across launches.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Config.standard)
            try data.write(to: fileURL, options: .atomic)
            return .ok(.standard)
        } catch {
            return .corrupt(
                "Couldn't write \(fileURL.lastPathComponent): "
                    + error.localizedDescription
            )
        }
    }
}
