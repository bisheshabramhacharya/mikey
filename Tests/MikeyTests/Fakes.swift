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
    }

    func stop() {
        stopCalls += 1
    }
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
    var stubbedOutput: TranscriptionOutput?
    var stubbedError: (any Error)?
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
        for phase in phasesToReport { onPhase(phase) }
        if let stubbedError { throw stubbedError }
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
