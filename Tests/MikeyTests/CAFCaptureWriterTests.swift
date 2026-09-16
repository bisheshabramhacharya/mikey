import AVFoundation
import Foundation
import Testing
@testable import Mikey

/// The whole point of the `.caf` capture file: audio on disk stays readable
/// without `finish()` — that's what a force-quit leaves behind.
struct CAFCaptureWriterTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sineBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        startingAt startFrame: Int
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(startFrame + i) / format.sampleRate
            data[i] = Float(sin(2 * .pi * 440 * t)) * 0.5
        }
        return buffer
    }

    /// "Survives force-quit": bytes committed to disk mid-write — no
    /// `finish()`, which is exactly the state a crash leaves — open and
    /// decode as audio. (The equivalent `.m4a` fails to even open: its moov
    /// atom is only patched at close.)
    @Test func fileOnDiskIsReadableWithoutFinish() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "live.caf")

        let writer = try CAFCaptureWriter(url: url)
        for chunk in 0..<10 {
            try writer.append(
                sineBuffer(format: writer.format, frames: 4096, startingAt: chunk * 4096)
            )
        }
        // Snapshot the committed bytes — user-space buffered tail is lost on
        // a real force-quit too, so this is the faithful "crash" artifact.
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk.count > 0)
        let crashedCopy = dir.appending(path: "crashed.caf")
        try onDisk.write(to: crashedCopy)
        writer.finish()

        let decoded = try AVAudioFile(forReading: crashedCopy)
        #expect(decoded.fileFormat.sampleRate == 44_100)
        #expect(decoded.fileFormat.channelCount == 1)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: decoded.processingFormat, frameCapacity: 8192
        )!
        try decoded.read(into: buffer)
        #expect(buffer.frameLength > 0)
        // And the decoded PCM carries actual signal, not just silence.
        var peak: Float = 0
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        #expect(peak > 0.1)
    }

    @Test func recordsDurationAsItWrites() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try CAFCaptureWriter(url: dir.appending(path: "s.caf"))
        #expect(writer.recordedDuration == 0)
        try writer.append(
            sineBuffer(format: writer.format, frames: 44_100, startingAt: 0)
        )
        #expect(abs(writer.recordedDuration - 1.0) < 0.001)
        writer.finish()
    }

    @Test func createsMissingParentDirectories() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Unsorted/deep/session.caf")
        let writer = try CAFCaptureWriter(url: url)
        writer.finish()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func appendAfterFinishThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try CAFCaptureWriter(url: dir.appending(path: "s.caf"))
        writer.finish()
        #expect(throws: CAFCaptureWriter.Failure.self) {
            try writer.append(
                sineBuffer(format: writer.format, frames: 128, startingAt: 0)
            )
        }
    }
}
