import AppKit
import Foundation

/// Runs one transcription job end to end: consent for the first model
/// download → `Transcriber` → atomic Transcript write → "Transcript ready"
/// notification that reveals the `.md` (SPEC §6).
///
/// Owns no job list — a single `transcribe` call is one job, which is what
/// the menu's per-Session action drives. Ticket #7's "Transcribe All Pending"
/// wraps this same surface in a serial loop.
@MainActor
public final class TranscriptionController {
    public enum Failure: LocalizedError {
        case transcriptWriteFailed(String)

        public var errorDescription: String? {
            switch self {
            case .transcriptWriteFailed(let detail):
                "Couldn't write the transcript: \(detail)"
            }
        }
    }

    /// What one `transcribe` call produced.
    public enum Outcome: Equatable, Sendable {
        /// `.md` written; value is its URL.
        case completed(URL)
        /// The user declined the model-download prompt — nothing ran.
        case declined
    }

    private let transcriber: any Transcriber
    private let consent: any ModelDownloadConsent
    private let writer: TranscriptWriter
    private let notifier: any NotificationPosting
    /// The download size the consent prompt quotes (SPEC §6: ~1.5 GB).
    private let downloadGB: Double

    public init(
        transcriber: any Transcriber = WhisperKitTranscriber(),
        consent: any ModelDownloadConsent = AlertModelDownloadConsent(),
        writer: TranscriptWriter = TranscriptWriter(),
        notifier: any NotificationPosting = UserNotificationPoster(),
        downloadGB: Double = WhisperKitTranscriber.approximateDownloadGB
    ) {
        self.transcriber = transcriber
        self.consent = consent
        self.writer = writer
        self.notifier = notifier
        self.downloadGB = downloadGB
    }

    /// Transcribes one pending Session. When the model isn't on disk yet the
    /// user is asked first — a decline (`.declined`) runs nothing and leaves
    /// the Session pending. `onPhase` reports download/transcribe progress on
    /// whatever thread the transcriber calls from.
    @discardableResult
    public func transcribe(
        _ session: PendingSession,
        model: String,
        onPhase: @escaping @Sendable (TranscriptionPhase) -> Void = { _ in }
    ) async throws -> Outcome {
        if await !transcriber.isModelReady(model) {
            guard await consent.requestConsent(
                model: model,
                approximateGB: downloadGB
            ) else {
                return .declined
            }
        }

        let output = try await transcriber.transcribe(
            audioAt: session.audioURL,
            model: model,
            onPhase: onPhase
        )

        // Only on success does the `.md` appear — the write itself is atomic,
        // so an interruption anywhere above stays pending (SPEC §6).
        do {
            try writer.write(
                writer.markdown(for: session, output: output),
                to: session.transcriptURL
            )
        } catch {
            throw Failure.transcriptWriteFailed(error.localizedDescription)
        }

        notifier.post(
            title: "Transcript ready — \(session.courseLabel)",
            body: session.transcriptURL.lastPathComponent,
            reveal: session.transcriptURL
        )
        return .completed(session.transcriptURL)
    }
}
