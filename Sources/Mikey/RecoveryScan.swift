import Foundation

/// A `.recording` marker sits next to a Session's eventual `.m4a`:
/// `2026-09-15_10-30.m4a` → `2026-09-15_10-30.recording`. It exists from
/// capture start until the `.m4a` is finalized — so a marker found at launch
/// means the previous run died somewhere between starting capture and
/// finishing the transcode (SPEC §7).
public enum RecordingMarker {
    /// Path extension of the marker file.
    public static let pathExtension = "recording"

    /// Marker URL for a Session's `.m4a` URL.
    public static func url(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension(pathExtension)
    }

    /// The `.m4a` a marker refers to (`name.recording` → `name.m4a`).
    public static func audioURL(for markerURL: URL) -> URL {
        markerURL.deletingPathExtension().appendingPathExtension("m4a")
    }

    /// Drops the marker. Contents are just the audio filename — enough to
    /// make the marker self-describing when browsing the Archive by hand.
    public static func create(for audioURL: URL) throws {
        try Data("\(audioURL.lastPathComponent)\n".utf8)
            .write(to: url(for: audioURL))
    }

    /// Deletes the marker once the `.m4a` is final. Missing is not an error.
    public static func remove(for audioURL: URL) {
        try? FileManager.default.removeItem(at: url(for: audioURL))
    }
}

/// The live capture artifact: a PCM `.caf` written next to the Session's
/// `.m4a`. CAF stays readable when un-closed (unlike `.m4a`), so a crash or
/// force-quit mid-capture leaves playable audio — see `CAFCaptureWriter`.
public enum CaptureFile {
    /// Path extension of the live capture file.
    public static let pathExtension = "caf"

    /// Capture URL for a Session's `.m4a` URL (`name.m4a` → `name.caf`).
    public static func url(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension(pathExtension)
    }

    /// The `.m4a` a capture file finalizes to (`name.caf` → `name.m4a`).
    public static func audioURL(for captureURL: URL) -> URL {
        captureURL.deletingPathExtension().appendingPathExtension("m4a")
    }
}

/// A Session that never reached a finalized `.m4a`: found at launch via its
/// `.recording` marker and/or a leftover `.caf` capture. The `.caf` is the
/// recoverable audio; the marker is the "we meant to finish this" flag.
public struct InterruptedRecording: Equatable, Sendable {
    /// The Session's eventual `.m4a` — its identity in the Archive.
    public let audioURL: URL
    /// The `.recording` marker on disk, if any.
    public let markerURL: URL?
    /// The `.caf` capture on disk, if any — the playable partial audio.
    public let captureURL: URL?

    public init(audioURL: URL, markerURL: URL?, captureURL: URL?) {
        self.audioURL = audioURL
        self.markerURL = markerURL
        self.captureURL = captureURL
    }
}

/// Launch-time scan of the Archive for Sessions that died mid-capture or
/// mid-finalize (SPEC §7).
public enum RecoveryScan {
    /// Finds interrupted Sessions under `archiveRoot` — at the root plus one
    /// folder deep, covering `Unsorted/` today and per-Course folders once
    /// they land. A `.recording` marker always counts; a `.caf` counts when
    /// its `.m4a` is absent or a marker is present (an unmarked `.caf` beside
    /// a finished `.m4a` isn't ours to touch).
    public static func interruptedRecordings(in archiveRoot: URL) -> [InterruptedRecording] {
        let fileManager = FileManager.default
        guard let topLevel = try? fileManager.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var folders = [archiveRoot]
        for item in topLevel where item.isDirectory {
            folders.append(item)
        }

        var markers: [URL: URL] = [:]  // audioURL → markerURL
        var captures: [URL: URL] = [:] // audioURL → captureURL
        for folder in folders {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            ) else { continue }
            for entry in entries {
                switch entry.pathExtension {
                case RecordingMarker.pathExtension:
                    markers[RecordingMarker.audioURL(for: entry)] = entry
                case CaptureFile.pathExtension:
                    captures[CaptureFile.audioURL(for: entry)] = entry
                default:
                    break
                }
            }
        }

        var found: [InterruptedRecording] = []
        for (audioURL, markerURL) in markers {
            found.append(InterruptedRecording(
                audioURL: audioURL,
                markerURL: markerURL,
                captureURL: captures[audioURL]
            ))
        }
        for (audioURL, captureURL) in captures where markers[audioURL] == nil {
            // Orphaned capture (crashed before the marker was written): only
            // recover when no `.m4a` already exists for the stem.
            guard !fileManager.fileExists(
                atPath: audioURL.path(percentEncoded: false)
            ) else { continue }
            found.append(InterruptedRecording(
                audioURL: audioURL,
                markerURL: nil,
                captureURL: captureURL
            ))
        }
        return found.sorted {
            $0.audioURL.lastPathComponent < $1.audioURL.lastPathComponent
        }
    }

    /// Deletes the marker, if any. The `.caf` is removed by
    /// `RecordingFinalizer` once the `.m4a` exists — never before.
    public static func clearMarker(of interrupted: InterruptedRecording) {
        if let markerURL = interrupted.markerURL {
            try? FileManager.default.removeItem(at: markerURL)
        }
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
