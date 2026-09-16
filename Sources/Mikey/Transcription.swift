import Foundation

/// One timestamped line of a Transcript: `start` is seconds into the
/// Recording, `text` the recognized speech for that segment.
public struct TranscriptSegment: Equatable, Sendable {
    public var start: TimeInterval
    public var text: String

    public init(start: TimeInterval, text: String) {
        self.start = start
        self.text = text
    }
}

/// What a Transcriber produces for one Recording: the segments plus the
/// Recording's duration and the model that ran, which the Transcript header
/// records (SPEC §6).
public struct TranscriptionOutput: Equatable, Sendable {
    public var segments: [TranscriptSegment]
    /// Recording length in seconds, rendered `h:mm:ss` in the Transcript.
    public var duration: TimeInterval
    /// The `whisperModel` config value that produced this output.
    public var model: String

    public init(segments: [TranscriptSegment], duration: TimeInterval, model: String) {
        self.segments = segments
        self.duration = duration
        self.model = model
    }
}

/// Progress checkpoints a Transcriber reports while a job runs; the menu maps
/// these onto "downloading … %", "loading model", "transcribing … %" (SPEC §2).
public enum TranscriptionPhase: Equatable, Sendable {
    /// One-time Whisper model fetch, 0…1 (SPEC §6: ~1.5 GB once).
    case downloadingModel(fraction: Double)
    /// Model on disk, loading into CoreML.
    case loadingModel
    /// Whisper running on the Recording, 0…1.
    case transcribing(fraction: Double)
}

/// The transcription seam. Implementations turn one Recording's audio into a
/// `TranscriptionOutput`; the filesystem side (where the `.md` lands, when the
/// notification fires) is `TranscriptionController`'s job, keeping this narrow
/// enough that ticket #7's serial queue can wrap a single Transcriber and run
/// jobs back to back.
public protocol Transcriber: Sendable {
    /// Whether `model` is fully on disk so `transcribe` can run with no
    /// network at all. When false the next `transcribe` downloads the model
    /// first — which is exactly when consent is required.
    func isModelReady(_ model: String) async -> Bool

    /// Transcribes the audio file at `url` with `model`, downloading and
    /// loading the model first if needed and reporting progress through
    /// `onPhase`. Throws on failure; a thrown job writes nothing and simply
    /// stays pending.
    func transcribe(
        audioAt url: URL,
        model: String,
        onPhase: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws -> TranscriptionOutput
}

/// Asks the user's permission before the one-time Whisper model download
/// (SPEC §6). Only consulted when the model isn't already on disk, so consent
/// is naturally a first-run-only step.
public protocol ModelDownloadConsent: Sendable {
    /// Returns true if the user accepts the download. `approximateGB` is the
    /// size the prompt should quote.
    func requestConsent(model: String, approximateGB: Double) async -> Bool
}
