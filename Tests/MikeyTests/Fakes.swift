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

    func post(title: String, body: String) {
        posted.append((title, body))
    }
}
