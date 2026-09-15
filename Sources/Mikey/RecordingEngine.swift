import Accelerate
import AVFoundation
import Foundation
import os

/// The capture half of a Session: microphone → incremental `.m4a` on disk.
/// Behind a protocol so tests can fake mic input.
public protocol RecordingEngine: AnyObject, Sendable {
    /// True between `start(to:)` and `stop()`.
    var isRecording: Bool { get }
    /// Seconds of audio written to the file so far.
    var elapsedTime: TimeInterval { get }
    /// Linear RMS level (0…1) of the most recently captured input buffer.
    var inputLevel: Float { get }

    /// Ensures TCC microphone permission, prompting the user on first use.
    func requestAccess() async -> Bool
    /// Starts capturing to `url`; throws if capture can't begin.
    func start(to url: URL) throws
    /// Ends capture and finalizes the file. Safe to call when not recording.
    func stop()
}

/// `RecordingEngine` backed by AVAudioEngine: input-node tap → format convert →
/// `M4AWriter`. Mic only — no system audio.
public final class MicRecordingEngine: RecordingEngine, @unchecked Sendable {
    public enum Failure: LocalizedError {
        case noInputDevice
        case cannotConvertInput

        public var errorDescription: String? {
            switch self {
            case .noInputDevice:
                "No microphone input device is available."
            case .cannotConvertInput:
                "Can't convert microphone input to the recording format."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var writer: M4AWriter?
    private var converter: AVAudioConverter?

    // Written on the realtime tap thread, read on the main thread.
    private let level = OSAllocatedUnfairLock<Float>(initialState: 0)
    private let writtenFrames = OSAllocatedUnfairLock<AVAudioFramePosition>(initialState: 0)

    public private(set) var isRecording = false

    public init() {}

    public var inputLevel: Float { level.withLock { $0 } }

    public var elapsedTime: TimeInterval {
        guard let writer else { return 0 }
        return Double(writtenFrames.withLock { $0 }) / writer.format.sampleRate
    }

    public func requestAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            true
        case .denied:
            false
        case .undetermined:
            await AVAudioApplication.requestRecordPermission()
        @unknown default:
            false
        }
    }

    public func start(to url: URL) throws {
        stop() // defensive: a prior Session must be fully torn down

        let writer = try M4AWriter(url: url)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw Failure.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: writer.format) else {
            throw Failure.cannotConvertInput
        }
        self.writer = writer
        self.converter = converter
        writtenFrames.withLock { $0 = 0 }
        level.withLock { $0 = 0 }

        do {
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
                [weak self] buffer, _ in
                self?.processInput(buffer)
            }
            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            self.writer = nil
            self.converter = nil
            // Don't leave a header-only shell file in the Archive.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public func stop() {
        guard writer != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.finish()
        writer = nil
        converter = nil
        isRecording = false
    }

    /// Runs on the realtime tap thread: updates the level meter, converts to
    /// the recording format, and appends to the `.m4a`.
    private func processInput(_ buffer: AVAudioPCMBuffer) {
        updateLevel(buffer)
        guard let converter, let writer else { return }

        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * writer.format.sampleRate
                / buffer.format.sampleRate
        ) + 128
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: writer.format,
            frameCapacity: capacity
        ) else { return }

        // PCM→PCM conversion runs synchronously and keeps converter state
        // across calls, which is what a streaming tap needs.
        do {
            try converter.convert(to: converted, from: buffer)
        } catch {
            return
        }
        guard converted.frameLength > 0 else { return }

        try? writer.append(converted)
        let appended = AVAudioFramePosition(converted.frameLength)
        writtenFrames.withLock { $0 += appended }
    }

    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var rms: Float = 0
            vDSP_rmsqv(channelData[channel], 1, &rms, vDSP_Length(frames))
            peak = max(peak, rms)
        }
        let newLevel = min(peak, 1)
        level.withLock { $0 = newLevel }
    }
}
