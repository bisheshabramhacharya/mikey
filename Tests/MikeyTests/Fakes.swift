import AVFoundation
import Foundation
@testable import Mikey

/// Fake mic input. Mutable fields are only touched from the test's main
/// thread, hence `@unchecked Sendable`.
final class FakeRecordingEngine: RecordingEngine, @unchecked Sendable {
    var accessGranted = true
    var requestAccessCalls = 0
    var startedURL: URL?
    var startError: (any Error)?
    var stopCalls = 0
    var stubbedElapsed: TimeInterval = 0
    var stubbedLevel: Float = 0
    var onCaptureStopped: (@Sendable () -> Void)?
    /// When true (default), `start` writes a tiny real `.caf` so the
    /// controller's finalize path is exercised end-to-end.
    var writesCaptureFile = true

    private var capture: CAFCaptureWriter?

    var isRecording: Bool { startedURL != nil && stopCalls == 0 }
    var elapsedTime: TimeInterval { stubbedElapsed }
    var inputLevel: Float { stubbedLevel }

    func requestAccess() async -> Bool {
        requestAccessCalls += 1
        return accessGranted
    }

    func start(to url: URL) throws {
        if let startError { throw startError }
        startedURL = url
        guard writesCaptureFile else { return }
        capture = try? CAFCaptureWriter(url: url)
        if let capture {
            // A few frames of silence — enough for the finalize transcode to
            // have something to chew on.
            if let buffer = AVAudioPCMBuffer(
                pcmFormat: capture.format,
                frameCapacity: 2_048
            ) {
                buffer.frameLength = 2_048
                buffer.floatChannelData?[0].update(repeating: 0, count: 2_048)
                try? capture.append(buffer)
            }
        }
    }

    func stop() {
        stopCalls += 1
        capture?.finish()
        capture = nil
    }
}

/// Fake free-space probe — `nil` means "capacity can't be determined".
/// A class so tests can change the reading after injecting it.
final class FakeDiskSpaceProbe: DiskSpaceProbing, @unchecked Sendable {
    var available: Int64?

    init(available: Int64? = nil) {
        self.available = available
    }

    func availableCapacity(at url: URL) -> Int64? { available }
}

struct FixedClock: Clock {
    var now: Date
}

final class FakeNotifier: NotificationPosting, @unchecked Sendable {
    private(set) var posted: [(title: String, body: String)] = []
    private(set) var revealed: [URL?] = []

    func post(title: String, body: String) {
        posted.append((title, body))
        revealed.append(nil)
    }

    func post(title: String, body: String, reveal url: URL?) {
        posted.append((title, body))
        revealed.append(url)
    }
}

/// Fake transcription backend: no model, no Whisper, just scripted output.
final class FakeTranscriber: Transcriber, @unchecked Sendable {
    var modelReady = false
    var isModelReadyCalls = 0
    var transcribeCalls = 0
    /// Files `transcribe` ran on, in call order — queue tests read this for
    /// oldest-first ordering.
    private(set) var transcribedURLs: [URL] = []
    var stubbedOutput: TranscriptionOutput?
    var stubbedError: (any Error)?
    /// Per-file failure hook, checked before `stubbedError` — lets a test
    /// fail one job in a queue while the others succeed.
    var errorForFile: ((URL) -> (any Error)?)?
    /// Awaited after the phases report, before the output/error — lets a
    /// test hold a job open mid-run (e.g. to record during a queue).
    var holdOpen: ((URL) async -> Void)?
    /// Phases reported on each `transcribe` call, in order.
    var phasesToReport: [TranscriptionPhase] = []
    /// Models `isModelReady` reports ready for; `nil` → use `modelReady`.
    var readyModels: Set<String>?

    func isModelReady(_ model: String) async -> Bool {
        isModelReadyCalls += 1
        return readyModels?.contains(model) ?? modelReady
    }

    func transcribe(
        audioAt url: URL,
        model: String,
        onPhase: @escaping @Sendable (TranscriptionPhase) -> Void
    ) async throws -> TranscriptionOutput {
        transcribeCalls += 1
        transcribedURLs.append(url)
        for phase in phasesToReport { onPhase(phase) }
        if let holdOpen { await holdOpen(url) }
        if let error = errorForFile?(url) ?? stubbedError { throw error }
        if let stubbedOutput { return stubbedOutput }
        return TranscriptionOutput(
            segments: [
                TranscriptSegment(start: 0, text: "Hello class"),
                TranscriptSegment(start: 134, text: "Second point"),
            ],
            duration: 4500,
            model: model
        )
    }
}

/// Scripted consent for the model-download prompt.
final class FakeModelDownloadConsent: ModelDownloadConsent, @unchecked Sendable {
    var grant = true
    private(set) var prompts: [String] = []

    func requestConsent(model: String, approximateGB: Double) async -> Bool {
        prompts.append(model)
        return grant
    }
}
