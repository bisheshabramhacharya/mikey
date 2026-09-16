import AVFoundation
import Foundation

/// Turns a finished `.caf` capture into the Archive's `.m4a` Recording by
/// streaming PCM through `M4AWriter`.
///
/// Crash-safe by ordering: the `.caf` is the source of truth until it is
/// deleted, a half-written `.m4a` is removed on failure, and a crash anywhere
/// in the sequence simply re-runs on the next launch's recovery pass.
public enum RecordingFinalizer {
    public enum Failure: LocalizedError {
        /// No `.caf` on disk to finalize.
        case captureMissing(URL)
        /// The capture's PCM format doesn't match the writer's contract.
        case formatMismatch
        /// Reading or writing failed mid-transcode.
        case transcoding(String)

        public var errorDescription: String? {
            switch self {
            case .captureMissing(let url):
                "No capture file at \(url.lastPathComponent)"
            case .formatMismatch:
                "Capture file's format doesn't match the recording format"
            case .transcoding(let detail):
                detail
            }
        }
    }

    /// Transcodes `captureURL` (PCM `.caf`) to `audioURL` (AAC `.m4a`), then
    /// deletes the `.caf`. Runs off the calling actor — a 75-minute capture
    /// is ~400 MB of PCM, so this is real work.
    public static func finalize(captureURL: URL, to audioURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try finalizeSynchronously(captureURL: captureURL, to: audioURL)
        }.value
    }

    /// The transcode proper, separated so callers already off the main actor
    /// (and tests) can run it inline.
    public static func finalizeSynchronously(captureURL: URL, to audioURL: URL) throws {
        guard FileManager.default.fileExists(
            atPath: captureURL.path(percentEncoded: false)
        ) else {
            throw Failure.captureMissing(captureURL)
        }
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: captureURL)
        } catch {
            throw Failure.captureMissing(captureURL)
        }
        // A previous finalize attempt may have died mid-write leaving a
        // broken `.m4a` — remove it so the rewrite starts clean.
        try? FileManager.default.removeItem(at: audioURL)

        let writer: M4AWriter
        do {
            writer = try M4AWriter(url: audioURL)
        } catch {
            throw Failure.transcoding(error.localizedDescription)
        }
        guard source.processingFormat.isEqual(writer.format) else {
            // M4AWriter's init already touched the file — remove the shell.
            writer.finish()
            try? FileManager.default.removeItem(at: audioURL)
            throw Failure.formatMismatch
        }

        do {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat,
                frameCapacity: 65_536
            ) else { throw Failure.transcoding("Couldn't allocate transcode buffer") }
            // `read(into:)` throws at end-of-file instead of returning 0, so
            // the loop is bounded by framePosition — correct even on an
            // un-closed CAF, whose length is derived from data-to-EOF.
            while source.framePosition < source.length {
                do {
                    try source.read(into: buffer)
                } catch {
                    break
                }
                if buffer.frameLength == 0 { break }
                try writer.append(buffer)
            }
            writer.finish()
        } catch let failure as Failure {
            // Don't leave a truncated `.m4a` looking finished in the Archive.
            try? FileManager.default.removeItem(at: audioURL)
            throw failure
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            throw Failure.transcoding(error.localizedDescription)
        }
        // The `.m4a` is final now — only delete the `.caf` here (never
        // earlier), so a crash mid-finalize can always re-run from source.
        // A stubborn leftover `.caf` is just clutter: the recovery scan
        // ignores it once the `.m4a` exists.
        try? FileManager.default.removeItem(at: captureURL)
    }
}
