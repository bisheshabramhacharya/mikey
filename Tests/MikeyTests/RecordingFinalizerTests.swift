import AVFoundation
import Foundation
import Testing
@testable import Mikey

/// `.caf` → `.m4a` transcode: the finalize step on clean stop and the
/// recovery path after a crash.
struct RecordingFinalizerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Writes ~1 s of 440 Hz sine into a `.caf`, closed properly — the state
    /// after a clean `engine.stop()`.
    private func makeCapture(at url: URL) throws {
        let writer = try CAFCaptureWriter(url: url)
        var startFrame = 0
        while startFrame < 44_100 {
            let buffer = AVAudioPCMBuffer(
                pcmFormat: writer.format, frameCapacity: 4096
            )!
            let n = min(4096, AVAudioFrameCount(44_100 - startFrame))
            buffer.frameLength = n
            let data = buffer.floatChannelData![0]
            for i in 0..<Int(n) {
                data[i] = Float(sin(2 * .pi * 440 * Double(startFrame + i) / 44_100)) * 0.5
            }
            try writer.append(buffer)
            startFrame += Int(n)
        }
        writer.finish()
    }

    @Test func finalizeProducesPlayableM4AAndDeletesCapture() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appending(path: "session.m4a")
        let capture = CaptureFile.url(for: audio)
        try makeCapture(at: capture)

        try await RecordingFinalizer.finalize(captureURL: capture, to: audio)

        #expect(exists(audio))
        #expect(!exists(capture))
        let decoded = try AVAudioFile(forReading: audio)
        #expect(decoded.fileFormat.sampleRate == 44_100)
        #expect(decoded.fileFormat.channelCount == 1)
        // ~1 s of audio (AAC priming/padding makes length approximate).
        #expect(abs(Double(decoded.length) - 44_100) < 4_096)
    }

    @Test func finalizeOverwritesBrokenM4AFromPriorAttempt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appending(path: "session.m4a")
        let capture = CaptureFile.url(for: audio)
        try makeCapture(at: capture)
        // A finalize attempt died mid-write: broken `.m4a` on disk.
        try Data("not a real m4a".utf8).write(to: audio)

        try await RecordingFinalizer.finalize(captureURL: capture, to: audio)

        let decoded = try AVAudioFile(forReading: audio) // must open now
        #expect(decoded.length > 0)
        #expect(!exists(capture))
    }

    @Test func missingCaptureThrowsAndKeepsNothingBehind() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appending(path: "session.m4a")
        let capture = CaptureFile.url(for: audio)

        await #expect(throws: RecordingFinalizer.Failure.self) {
            try await RecordingFinalizer.finalize(captureURL: capture, to: audio)
        }
        #expect(!exists(audio))
    }

    @Test func corruptCaptureKeepsCaptureForRetry() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appending(path: "session.m4a")
        let capture = CaptureFile.url(for: audio)
        try Data("garbage, not a caf".utf8).write(to: capture)

        await #expect(throws: RecordingFinalizer.Failure.self) {
            try await RecordingFinalizer.finalize(captureURL: capture, to: audio)
        }
        // `.caf` is the source of truth — kept so the next launch can retry.
        #expect(exists(capture))
        #expect(!exists(audio))
    }
}
