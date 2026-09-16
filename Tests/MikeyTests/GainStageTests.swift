import Accelerate
import AVFoundation
import Foundation
import Testing
@testable import Mikey

/// Gain math at the seam: quiet input gets the full configured boost, loud
/// input saturates smoothly at ±1 instead of clipping (SPEC §3).
struct GainStageTests {
    private let stereoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 2,
        interleaved: false
    )!

    private func sineBuffer(
        amplitude: Float,
        frames: AVAudioFrameCount = 4096,
        frequency: Double = 440
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(stereoFormat.channelCount) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                let t = Double(i) / stereoFormat.sampleRate
                data[i] = Float(sin(2 * .pi * frequency * t)) * amplitude
            }
        }
        return buffer
    }

    private func peak(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> Float {
        var max: Float = 0
        vDSP_maxmgv(
            buffer.floatChannelData![channel], 1, &max,
            vDSP_Length(buffer.frameLength)
        )
        return max
    }

    @Test func defaultGainIsPlus12dB() {
        #expect(GainStage.defaultGainDB == 12)
        // +12 dB ≈ ×3.98 amplitude.
        #expect(abs(GainStage().linearGain - 3.981) < 0.001)
    }

    @Test func gainDBConfiguresLinearMultiplier() {
        #expect(abs(GainStage(gainDB: 0).linearGain - 1) < 0.0001)
        #expect(abs(GainStage(gainDB: 6).linearGain - 1.995) < 0.001)
        #expect(abs(GainStage(gainDB: -6).linearGain - 0.501) < 0.001)
    }

    @Test func quietSignalGetsFullBoost() {
        // −26 dBFS room tone: tanh is ≈identity this low, so the whole
        // +12 dB boost lands on the recording (within a few percent).
        let stage = GainStage()
        let boosted = stage.process(0.05)
        #expect(boosted > 0.19)
        #expect(boosted <= 0.05 * stage.linearGain)
    }

    @Test func loudSignalSoftLimitsBelowFullScale() {
        // 0.9 → ×3.98 would hard-clip at ±1; the limiter saturates under it.
        let stage = GainStage()
        let out = stage.process(0.9)
        #expect(out > 0.9)          // still louder than the raw input
        #expect(out < 1.0)          // never reaches full scale — no clip edge
        #expect(stage.process(-0.9) == -out) // symmetric on the negative side
    }

    @Test func zeroGainPassesQuietThrough() {
        let stage = GainStage(gainDB: 0)
        #expect(abs(stage.process(0.05) - 0.05) < 0.001)
    }

    @Test func bufferProcessingBoostsEveryChannel() {
        let stage = GainStage()
        let buffer = sineBuffer(amplitude: 0.05)
        stage.process(buffer)
        // Both channels boosted by ~+12 dB (×3.98); small tanh sag at the
        // boosted peak keeps the result just under the linear product.
        for channel in 0..<2 {
            let peak = peak(buffer, channel: channel)
            #expect(peak > 0.17 && peak <= 0.05 * stage.linearGain)
        }
    }

    @Test func bufferProcessingLimitsWithoutHardClip() {
        let stage = GainStage()
        let buffer = sineBuffer(amplitude: 0.9)
        stage.process(buffer)
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(buffer.frameLength) {
                #expect(abs(data[i]) < 1.0)
            }
        }
    }

    @Test func nonFloatBufferPassesThrough() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100,
            channels: 1,
            interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        buffer.frameLength = 128
        GainStage().process(buffer) // must not crash on nil floatChannelData
    }
}
