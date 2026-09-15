import Foundation
import Testing
@testable import Mikey

@MainActor
struct SessionControllerTests {
    private let tempDir: URL
    private let engine: FakeRecordingEngine
    private let notifier: FakeNotifier
    private let clock: FixedClock
    private let controller: SessionController

    private static var sessionStart: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 15
        components.hour = 10; components.minute = 30
        return Calendar.current.date(from: components)!
    }

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = FixedClock(now: Self.sessionStart)
        engine = FakeRecordingEngine()
        notifier = FakeNotifier()
        controller = SessionController(
            engine: engine,
            archive: Archive(root: tempDir),
            clock: clock,
            notifier: notifier
        )
    }

    @Test func startFilesQuickRecordIntoUnsorted() async throws {
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let session = try await controller.startSession()

        #expect(engine.requestAccessCalls == 1)
        // The engine captures to the `.caf` sibling; the Session's fileURL is
        // the `.m4a` it finalizes to.
        #expect(engine.startedURL == CaptureFile.url(for: session.fileURL))
        #expect(session.startedAt == Self.sessionStart)
        #expect(
            session.fileURL.path(percentEncoded: false)
                == tempDir.appending(path: "Unsorted/2026-09-15_10-30.m4a")
                    .path(percentEncoded: false)
        )
    }

    @Test func startWithoutMicPermissionThrows() async {
        defer { try? FileManager.default.removeItem(at: tempDir) }
        engine.accessGranted = false

        await #expect(throws: SessionController.Failure.self) {
            try await controller.startSession()
        }
        #expect(engine.startedURL == nil)
    }

    @Test func startFailurePropagates() async {
        defer { try? FileManager.default.removeItem(at: tempDir) }
        struct Boom: Error {}
        engine.startError = Boom()

        await #expect {
            try await controller.startSession()
        } throws: { error in
            guard case .captureFailed = error as? SessionController.Failure else {
                return false
            }
            return true
        }
    }

    @Test func stopEndsCaptureAndNotifies() async throws {
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let session = try await controller.startSession()

        await controller.stopSession(session)

        #expect(engine.stopCalls == 1)
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted.first?.title == "Recording stopped")
        #expect(notifier.posted.first?.body == "2026-09-15_10-30.m4a")
        // Stop finalizes: the `.m4a` exists and the `.caf` is gone.
        #expect(FileManager.default.fileExists(
            atPath: session.fileURL.path(percentEncoded: false)
        ))
        #expect(!FileManager.default.fileExists(
            atPath: CaptureFile.url(for: session.fileURL).path(percentEncoded: false)
        ))
    }

    @Test func elapsedAndLevelPassThroughFromEngine() {
        defer { try? FileManager.default.removeItem(at: tempDir) }
        engine.stubbedElapsed = 95
        engine.stubbedLevel = 0.4

        #expect(controller.elapsedTime == 95)
        #expect(controller.inputLevel == 0.4)
    }
}
