import AVFoundation
import Foundation
import WhisperKit

/// `Transcriber` backed by WhisperKit — CoreML-accelerated Whisper running
/// entirely on-device (SPEC §6).
///
/// Model handling: the `whisperModel` config name ("large-v3-turbo") is a
/// shorthand; WhisperKit's HuggingFace repo `argmaxinc/whisperkit-coreml`
/// stores variants under folders like `openai_whisper-large-v3_turbo`
/// (underscore before `turbo`). `resolveVariant` maps the config name onto the
/// token WhisperKit's downloader globs for, and `localModelFolder` applies the
/// same glob to the on-disk cache so a completed download runs with zero
/// network. Downloads land under `downloadBase` in the Hub layout
/// (`models/<repo>/<variant folder>/`) and resume via `.metadata` sidecars —
/// an interrupted fetch picks up where it left off on the next trigger.
///
/// An actor: the loaded `WhisperKit` pipeline is non-Sendable and stays
/// isolated here, and jobs serialize through the actor — which is also the
/// "one at a time" guarantee the queue ticket builds on.
public actor WhisperKitTranscriber: Transcriber {
    public enum Failure: LocalizedError {
        case modelUnavailable(String)
        case unreadableAudio(String)
        case emptyTranscript

        public var errorDescription: String? {
            switch self {
            case .modelUnavailable(let detail):
                "The Whisper model isn't available: \(detail)"
            case .unreadableAudio(let detail):
                "Couldn't read the recording for transcription: \(detail)"
            case .emptyTranscript:
                "Whisper produced no transcript."
            }
        }
    }

    /// The HF repo WhisperKit variants live in (fixed upstream).
    public static let modelRepo = "argmaxinc/whisperkit-coreml"
    /// Size quoted by the consent prompt for the default model (SPEC §6).
    public static let approximateDownloadGB = 1.5

    /// Base directory for the model cache. Default:
    /// `~/Library/Application Support/Mikey/WhisperModels` — Application
    /// Support rather than Caches so the system can't evict a 1.5 GB asset
    /// that takes a real download to replace (SPEC §6).
    public let downloadBase: URL

    /// The loaded pipeline, kept across jobs so consecutive transcriptions
    /// don't pay model load again.
    private var cachedVariant: String?
    private var cachedKit: WhisperKit?

    public static var defaultDownloadBase: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appending(path: "Mikey", directoryHint: .isDirectory)
            .appending(path: "WhisperModels", directoryHint: .isDirectory)
    }

    public init(downloadBase: URL = WhisperKitTranscriber.defaultDownloadBase) {
        self.downloadBase = downloadBase
    }

    /// True when a complete model folder for `model` already sits in the local
    /// cache — meaning `transcribe` runs offline and needs no consent.
    public nonisolated func isModelReady(_ model: String) -> Bool {
        localModelFolder(for: Self.resolveVariant(model)) != nil
    }

    public func transcribe(
        audioAt url: URL,
        model: String,
        onPhase: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws -> TranscriptionOutput {
        let variant = Self.resolveVariant(model)
        let duration = try Self.audioDuration(of: url)
        let kit = try await pipeline(for: variant, onPhase: onPhase)

        // Segment discoveries arrive as Whisper finishes windows; the furthest
        // segment end over the file's duration is a honest 0…1 progress.
        kit.segmentDiscoveryCallback = { segments in
            guard duration > 0, let last = segments.map(\.end).max() else { return }
            onPhase(.transcribing(fraction: min(0.99, Double(last) / duration)))
        }
        defer { kit.segmentDiscoveryCallback = nil }

        // `.incremental` streams the file in VAD-cut chunks instead of decoding
        // ~300 MB of PCM for a 75-minute lecture into memory at once.
        let options = AudioInputOptions(
            audioLoadingMode: .incremental(chunkDurationSeconds: 120, maxBufferedChunks: 2)
        )
        let results = try await kit.transcribe(
            audioPath: url.path(percentEncoded: false),
            audioInputOptions: options,
            // Keep <|…|> markers out of the Transcript's segment text.
            decodeOptions: DecodingOptions(skipSpecialTokens: true)
        )
        onPhase(.transcribing(fraction: 1.0))

        let segments = results
            .flatMap(\.segments)
            .sorted { $0.start < $1.start }
            .map { TranscriptSegment(start: TimeInterval($0.start), text: $0.text) }
        guard !segments.isEmpty else { throw Failure.emptyTranscript }
        return TranscriptionOutput(segments: segments, duration: duration, model: model)
    }

    /// Reuses the loaded pipeline or builds it: local folder → load only;
    /// otherwise download (reporting `.downloadingModel`) then load.
    private func pipeline(
        for variant: String,
        onPhase: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws -> WhisperKit {
        if cachedVariant == variant, let cachedKit {
            return cachedKit
        }

        let folder: URL
        if let local = localModelFolder(for: variant) {
            folder = local
        } else {
            onPhase(.downloadingModel(fraction: 0))
            do {
                folder = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: downloadBase,
                    from: Self.modelRepo
                ) { progress in
                    onPhase(.downloadingModel(fraction: progress.fractionCompleted))
                }
            } catch {
                throw Failure.modelUnavailable(error.localizedDescription)
            }
        }

        onPhase(.loadingModel)
        let kit = try await WhisperKit(WhisperKitConfig(
            downloadBase: downloadBase,  // the tokenizer caches beside the model
            modelFolder: folder.path(percentEncoded: false),
            verbose: false,
            load: true,
            download: false
        ))
        cachedVariant = variant
        cachedKit = kit
        return kit
    }

    /// The on-disk folder holding a usable copy of `variant`, or nil. Mirrors
    /// WhisperKit's remote search — the downloader globs `*<variant>/*` over
    /// repo file paths, i.e. a folder counts when its name *ends with* the
    /// variant (`_954MB` quantized folders don't claim the plain variant);
    /// `*openai*<variant>` breaks openai-vs-distil ties. A match must also
    /// contain the three CoreML components `loadModels` looks for, so a
    /// half-downloaded folder doesn't count as ready (it gets resumed by the
    /// download path instead).
    nonisolated func localModelFolder(for variant: String) -> URL? {
        let repoDir = downloadBase
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: Self.modelRepo, directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: repoDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let folders = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        var matches = folders.filter {
            $0.lastPathComponent.hasSuffix(variant)
        }
        if matches.count != 1 {
            matches = folders.filter {
                let name = $0.lastPathComponent
                return name.hasSuffix(variant) && name.contains("openai")
            }
        }
        guard matches.count == 1, let folder = matches.first else { return nil }
        return Self.hasModelComponents(folder) ? folder : nil
    }

    /// `loadModels` needs MelSpectrogram + AudioEncoder + TextDecoder, each as
    /// a compiled `.mlmodelc` or source `.mlpackage` (ModelUtilities).
    static func hasModelComponents(_ folder: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: folder.path(percentEncoded: false)
        ) else { return false }
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { base in
            names.contains { $0.hasPrefix(base + ".") }
        }
    }

    /// Maps a `whisperModel` config value onto the token WhisperKit searches
    /// the repo for: "large-v3-turbo" → "large-v3_turbo" (repo folders use an
    /// underscore), an already-qualified `openai_whisper-…`/`distil-whisper_…`
    /// folder name passes through, and plain names ("tiny", "large-v3") work
    /// unchanged. A trailing quantized size suffix (`_954MB`) also passes
    /// through, so a config can pin e.g. `openai_whisper-large-v3_turbo_954MB`.
    static func resolveVariant(_ model: String) -> String {
        var name = model.trimmingCharacters(in: .whitespaces)
        for prefix in ["openai_whisper-", "whisper-"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if name.hasSuffix("-turbo") {
            name = name.replacingOccurrences(of: "-turbo", with: "_turbo")
        }
        return name
    }

    /// Seconds of audio in the Recording, from the file's own header.
    static func audioDuration(of url: URL) throws -> TimeInterval {
        do {
            let file = try AVAudioFile(forReading: url)
            let rate = file.fileFormat.sampleRate
            guard rate > 0 else { return 0 }
            return Double(file.length) / rate
        } catch {
            throw Failure.unreadableAudio(error.localizedDescription)
        }
    }
}
