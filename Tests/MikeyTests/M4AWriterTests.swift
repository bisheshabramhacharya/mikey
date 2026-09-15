import AVFoundation
import Foundation
import Testing
@testable import Mikey

/// Generates deterministic PCM (a 440 Hz sine) in the writer's processing
/// format, mimicking what the input tap hands to the engine.
private func sineBuffer(
    format: AVAudioFormat,
    frames: AVAudioFrameCount,
    startingAt startFrame: Int,
    frequency: Double = 440
) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(format.channelCount) {
        let data = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) {
            let t = Double(startFrame + i) / format.sampleRate
            data[i] = Float(sin(2 * .pi * frequency * t)) * 0.5
        }
    }
    return buffer
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct M4AWriterTests {
    @Test func appendsPCM_producesPlayableAACFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.m4a")

        let writer = try M4AWriter(url: url)
        let format = writer.format
        let seconds = 2.0
        let chunk: AVAudioFrameCount = 4096
        var startFrame = 0
        while Double(startFrame) < format.sampleRate * seconds {
            let remaining = AVAudioFrameCount(format.sampleRate * seconds) - AVAudioFrameCount(startFrame)
            let n = min(chunk, remaining)
            try writer.append(sineBuffer(format: format, frames: n, startingAt: startFrame))
            startFrame += Int(n)
        }
        writer.finish()

        // The .m4a exists, is non-trivial in size, and re-opens as audio.
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        )
        #expect(size > 1_000)

        let decoded = try AVAudioFile(forReading: url)
        #expect(decoded.fileFormat.sampleRate == 44_100)
        #expect(decoded.fileFormat.channelCount == 1)
        // AAC priming/padding makes the decoded length approximate.
        #expect(abs(Double(decoded.length) - format.sampleRate * seconds) < 4_096)
    }

    @Test func recordsDurationAsItWrites() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.m4a")

        let writer = try M4AWriter(url: url)
        #expect(writer.recordedDuration == 0)

        try writer.append(sineBuffer(format: writer.format, frames: 44_100, startingAt: 0))
        #expect(abs(writer.recordedDuration - 1.0) < 0.001)
        writer.finish()
    }

    @Test func createsMissingParentDirectories() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Unsorted/deep/session.m4a")

        let writer = try M4AWriter(url: url)
        writer.finish()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func appendAfterFinishThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.m4a")

        let writer = try M4AWriter(url: url)
        writer.finish()
        #expect(throws: M4AWriter.Failure.self) {
            try writer.append(sineBuffer(format: writer.format, frames: 128, startingAt: 0))
        }
    }

    /// "Survives a mid-write interruption": encoded audio reaches the file on
    /// disk before `finish()` — capture is never a memory buffer flushed at the
    /// end.
    @Test func dataIsOnDiskBeforeFinish() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "session.m4a")

        let writer = try M4AWriter(url: url)
        var startFrame = 0
        for _ in 0..<20 { // ~1.9 s at 4096 frames/append
            try writer.append(
                sineBuffer(format: writer.format, frames: 4096, startingAt: startFrame)
            )
            startFrame += 4096
        }
        let sizeMidWrite = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        )
        #expect(sizeMidWrite > 0)
        writer.finish()
    }
}
