import AVFoundation
import Foundation

/// Writes PCM buffers to a single AAC `.m4a` Recording on disk.
///
/// Samples are encoded and written to the final Archive path as they arrive —
/// never buffered to memory — so the file on disk always trails live capture by
/// only the encoder's packet size. Call `finish()` to finalize the container.
public final class M4AWriter {
    /// Lecture capture format: mono AAC at 44.1 kHz / 96 kbps (~32 MB per 75
    /// minutes — well under the spec's ~60–90 MB stereo budget, and all a
    /// single distant voice needs for Whisper).
    public static var recordingSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
    }

    public let url: URL

    /// The PCM format buffers handed to `append(_:)` must be in — float32
    /// non-interleaved at the rate/channel count of `recordingSettings`.
    public let format: AVAudioFormat

    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0

    public init(url: URL, settings: [String: Any] = M4AWriter.recordingSettings) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        format = file!.processingFormat
    }

    /// Seconds of audio encoded so far.
    public var recordedDuration: TimeInterval {
        Double(framesWritten) / format.sampleRate
    }

    /// Encodes and appends one PCM buffer. Buffers must match `format`.
    public func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw Failure.alreadyFinished }
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    /// Finalizes the `.m4a` container (writes the trailing metadata that makes
    /// the file playable). Idempotent; `append` after `finish` throws.
    public func finish() {
        // Releasing the AVAudioFile closes the underlying AudioFile, which
        // flushes and patches the MPEG-4 atoms.
        file = nil
    }

    public enum Failure: Error {
        case alreadyFinished
    }
}
