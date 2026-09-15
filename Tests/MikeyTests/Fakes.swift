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

    func post(title: String, body: String) {
        posted.append((title, body))
    }
}
