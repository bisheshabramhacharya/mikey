import AVFoundation
import Foundation

/// The live capture artifact: PCM16 mono in a CAF container, written next to
/// the Session's eventual `.m4a` as `<name>.caf`.
///
/// Why CAF and not `.m4a` directly: an `.m4a`'s moov atom is only patched
/// when the file closes, so a force-quit leaves an unreadable shell of audio
/// bytes. A CAF's data chunk may carry size `-1` ("to end of file"), so an
/// un-closed CAF still opens and decodes — a crash leaves playable audio.
/// On clean stop (or at the next launch's recovery pass) the `.caf` is
/// transcoded into the Archive's `.m4a` by `RecordingFinalizer`.
public final class CAFCaptureWriter {
    /// Lossless PCM: 44.1 kHz / 16-bit / mono — ~5 MB/min during capture.
    /// The file is transient (transcoded + deleted at finalize), so the
    /// larger footprint never lives in the Archive.
    public static var captureSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
    }

    public let url: URL

    /// The PCM format buffers handed to `append(_:)` must be in — float32
    /// non-interleaved at 44.1 kHz mono, same contract as `M4AWriter`, so the
    /// engine's converter chain is unchanged.
    public let format: AVAudioFormat

    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        file = try AVAudioFile(
            forWriting: url,
            settings: Self.captureSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        format = file!.processingFormat
    }

    /// Seconds of audio written so far.
    public var recordedDuration: TimeInterval {
        Double(framesWritten) / format.sampleRate
    }

    /// Appends one PCM buffer. Buffers must match `format`.
    public func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw Failure.alreadyFinished }
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    /// Closes the CAF. Idempotent; `append` after `finish` throws. Skipped
    /// entirely on force-quit — the file on disk is still readable.
    public func finish() {
        file = nil
    }

    public enum Failure: Error {
        case alreadyFinished
    }
}
